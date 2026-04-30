// LetterRecognizer.swift
// PrimaeNative
//
// CoreML-backed letter recognition service. Takes a freehand path of
// CGPoints and asks `GermanLetterRecognizer.mlpackage` to classify the
// result as one of 53 classes (A–Z, a–z, ß). Used by the freeWrite phase
// feedback and the freeform writing mode.

import CoreGraphics
import CoreML
import Foundation
import OSLog
import Vision

// MARK: - Classifier intermediate type

/// D3 (ROADMAP): framework-agnostic projection of a Vision
/// `VNClassificationObservation`. Lets the rest of the recognizer
/// pipeline stay free of Vision dependencies and lets tests inject a
/// deterministic classifier without bundling a real `.mlpackage`.
struct LetterClassification: Equatable, Sendable {
    let identifier: String
    let confidence: Float
}

// MARK: - Result type

/// Outcome of a single recognition call.
struct RecognitionResult: Equatable, Sendable {
    /// Top-1 label returned by the model.
    let predictedLetter: String
    /// Calibrated confidence (0–1) for the top label.
    let confidence: CGFloat
    /// T5 (ROADMAP_V5): pre-calibration softmax confidence. Lets the
    /// thesis report the calibrator's effect on classification decisions
    /// (raw vs adjusted, decision flip rate) instead of only the
    /// post-calibration figure. Optional so synthesised results from
    /// stubs / tests / freeform-mode placeholders remain unaffected.
    let rawConfidence: CGFloat?
    /// Top-3 labels with calibrated confidences, descending.
    let topThree: [TopCandidate]
    /// True when `predictedLetter` matches `expectedLetter` case-insensitively.
    /// For freeform mode (no expectation), this is always `false`.
    let isCorrect: Bool

    /// Nonisolated so the recognizer's `Task.detached` background context
    /// can construct results without bouncing back to MainActor — the
    /// package's `.defaultIsolation(MainActor.self)` would otherwise
    /// pin a custom init to the main actor.
    nonisolated init(predictedLetter: String, confidence: CGFloat,
                     rawConfidence: CGFloat? = nil,
                     topThree: [TopCandidate], isCorrect: Bool) {
        self.predictedLetter = predictedLetter
        self.confidence = confidence
        self.rawConfidence = rawConfidence
        self.topThree = topThree
        self.isCorrect = isCorrect
    }

    struct TopCandidate: Equatable, Sendable {
        let letter: String
        let confidence: CGFloat
    }
}

// MARK: - Protocol

/// Async recognition seam. Swap `StubLetterRecognizer` in tests.
protocol LetterRecognizerProtocol: Sendable {
    /// Recognise the rasterised stroke. `strokeStartIndices` lists
    /// indices into `points` where a fresh stroke begins (after a
    /// finger-up between strokes); the rasterizer breaks the polyline
    /// at those indices so multi-stroke letters (F, E, H, …) aren't
    /// drawn with phantom diagonals connecting the strokes — that
    /// silhouette read as a different glyph (F → P) on the model.
    /// Pass `[]` (or use the convenience overload below) when there
    /// are no breaks. `historicalFormScores` is the child's prior
    /// recognition-accuracy history for the expected letter — the
    /// calibrator uses it to award a small confidence boost on letters
    /// the child has practised reliably (review item W-21 / P-4).
    func recognize(points: [CGPoint],
                   strokeStartIndices: [Int],
                   canvasSize: CGSize,
                   expectedLetter: String?,
                   historicalFormScores: [CGFloat]) async -> RecognitionResult?
    /// Whether the recognizer's backing model is actually loaded and
    /// ready for inference. `false` means every call to `recognize`
    /// will return `nil`; the UI uses this to distinguish "model
    /// missing" from "model said no" and show a diagnostic banner.
    func isModelAvailable() async -> Bool
}

extension LetterRecognizerProtocol {
    /// Convenience that omits stroke breaks (single-stroke letters,
    /// freeform mode where stroke separation isn't tracked yet) and
    /// `historicalFormScores`. Lets older call sites keep the
    /// 3-argument shape.
    func recognize(points: [CGPoint],
                   canvasSize: CGSize,
                   expectedLetter: String?,
                   historicalFormScores: [CGFloat] = []) async -> RecognitionResult? {
        await recognize(points: points,
                        strokeStartIndices: [],
                        canvasSize: canvasSize,
                        expectedLetter: expectedLetter,
                        historicalFormScores: historicalFormScores)
    }
}

// MARK: - CoreML-backed recognizer

private nonisolated(unsafe) let recognizerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
    category: "LetterRecognizer"
)

/// Production recognizer backed by `GermanLetterRecognizer.mlpackage`.
///
/// The model is loaded lazily on first `recognize(…)` call so app startup
/// doesn't pay the Vision framework warm-up cost. If the model file is
/// missing or fails to load, the recognizer logs a warning and every
/// subsequent call returns `nil` — the app falls back to Fréchet-only
/// scoring gracefully.
///
/// Declared `nonisolated` to opt out of the package-level
/// `defaultIsolation(MainActor.self)` — all its work needs to happen on
/// the cooperative pool inside a detached Task (see `recognize`), which
/// can only call nonisolated members.
nonisolated final class CoreMLLetterRecognizer: LetterRecognizerProtocol, @unchecked Sendable {

    // MARK: Static model cache

    /// nonisolated(unsafe) because Vision's model handles are expensive to
    /// load (~50 ms) and are safe to share across threads after
    /// construction. Guarded by `loadLock` on first touch.
    private nonisolated(unsafe) static var sharedModel: VNCoreMLModel?
    private nonisolated(unsafe) static var didAttemptLoad = false
    private static let loadLock = NSLock()

    private let calibrator: ConfidenceCalibrator
    /// D3 (ROADMAP): the classification step is the only piece of the
    /// recognize() pipeline that needs Vision. By taking it as an
    /// injectable closure, tests can swap in a deterministic stub
    /// without bundling a `.mlpackage` into the test target — the
    /// rendering step (renderToImage) and the post-processing step
    /// (makeResult + ConfidenceCalibrator) become testable
    /// end-to-end.
    typealias Classifier = @Sendable (CGImage) -> [LetterClassification]
    private let classify: Classifier

    // MARK: Init

    init(calibrator: ConfidenceCalibrator = ConfidenceCalibrator(),
         classifier: Classifier? = nil) {
        self.calibrator = calibrator
        self.classify = classifier ?? Self.defaultClassifier
    }

    /// Production classifier: lazy-load the bundled `.mlpackage`, run a
    /// `VNCoreMLRequest`, project the observations onto the
    /// framework-agnostic `LetterClassification` type so the rest of
    /// the pipeline never touches Vision. Returns `[]` when the model
    /// can't be loaded — the caller treats empty as "skip recognition".
    /// Spelled with the full closure type rather than the `Classifier`
    /// typealias because Swift's stored-property-initializer rules
    /// flag a covariant-Self reference when a typealias inside a final
    /// class is used to type a `static let`.
    private static let defaultClassifier: @Sendable (CGImage) -> [LetterClassification] = { image in
        guard let model = CoreMLLetterRecognizer.loadModelIfNeeded() else { return [] }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results as? [VNClassificationObservation] ?? []
            return observations.map {
                LetterClassification(identifier: $0.identifier, confidence: $0.confidence)
            }
        } catch {
            recognizerLogger.warning("Vision request failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: LetterRecognizerProtocol

    /// First access compiles the `.mlpackage` and loads the VNCoreMLModel —
    /// both blocking on disk and GPU warm-up. Ship it to a detached Task
    /// so the probe never runs on MainActor; otherwise iOS surfaces
    /// "should not be called on main thread" and the gesture subsystem
    /// times out waiting for the main runloop.
    func isModelAvailable() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            Self.loadModelIfNeeded() != nil
        }.value
    }

    func recognize(points: [CGPoint],
                   strokeStartIndices: [Int],
                   canvasSize: CGSize,
                   expectedLetter: String?,
                   historicalFormScores: [CGFloat]) async -> RecognitionResult? {
        guard points.count >= 2, canvasSize.width > 0, canvasSize.height > 0 else {
            return nil
        }
        let expected = expectedLetter
        let calibratorCopy = calibrator
        let history = historicalFormScores
        let classifier = classify
        let breaks = strokeStartIndices
        // The entire hot path — model load on first call, 40×40 CGContext
        // rasterization, VNImageRequestHandler.perform — is CPU-heavy and
        // must NOT execute on the MainActor. A detached Task runs on the
        // cooperative thread pool and does not inherit the caller's
        // isolation, so every synchronous call inside happens off-main.
        return await Task.detached(priority: .userInitiated) {
            guard let image = Self.renderToImage(points: points,
                                                  strokeStartIndices: breaks,
                                                  canvasSize: canvasSize) else {
                return nil
            }
            let classifications = classifier(image)
            guard !classifications.isEmpty else { return nil }
            return Self.makeResult(
                from: classifications,
                expectedLetter: expected,
                calibrator: calibratorCopy,
                historicalFormScores: history
            )
        }.value
    }

    // MARK: - Model loading

    private static func loadModelIfNeeded() -> VNCoreMLModel? {
        loadLock.lock()
        defer { loadLock.unlock() }
        if didAttemptLoad { return sharedModel }
        didAttemptLoad = true
        sharedModel = loadModel()
        return sharedModel
    }

    private static func loadModel() -> VNCoreMLModel? {
        let candidates: [Bundle] = {
            var bundles: [Bundle] = [.main]
            let name = "PrimaeNative_PrimaeNative"
            if let b = Bundle(identifier: name) { bundles.append(b) }
            bundles.append(contentsOf: Bundle.allBundles.filter {
                $0.bundlePath.hasSuffix(name + ".bundle")
            })
            bundles.append(contentsOf: Bundle.allFrameworks.filter {
                $0.bundlePath.hasSuffix(name + ".bundle")
            })
            return bundles
        }()

        let modelURL: URL? = {
            // Possible subdirectories — SwiftPM's `.copy("Resources")`
            // preserves the tree, Xcode's resource processing flattens
            // into the top-level bundle root. Try all the plausible
            // locations before giving up.
            let subdirs: [String?] = [nil, "Resources/ML", "ML", "Resources"]
            for bundle in candidates {
                for sub in subdirs {
                    if let u = bundle.url(
                        forResource: "GermanLetterRecognizer",
                        withExtension: "mlmodelc",
                        subdirectory: sub
                    ) {
                        return u
                    }
                }
                for sub in subdirs {
                    if let u = bundle.url(
                        forResource: "GermanLetterRecognizer",
                        withExtension: "mlpackage",
                        subdirectory: sub
                    ) {
                        do {
                            return try MLModel.compileModel(at: u)
                        } catch {
                            recognizerLogger.warning("Failed to compile mlpackage at \(u.path): \(error.localizedDescription)")
                            continue
                        }
                    }
                }
            }
            return nil
        }()

        guard let url = modelURL else {
            recognizerLogger.warning("GermanLetterRecognizer model not found in any bundle — letter recognition disabled")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let core = try MLModel(contentsOf: url, configuration: config)
            return try VNCoreMLModel(for: core)
        } catch {
            recognizerLogger.warning("Could not initialize VNCoreMLModel: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Result post-processing

    static func makeResult(
        from classifications: [LetterClassification],
        expectedLetter: String?,
        calibrator: ConfidenceCalibrator,
        historicalFormScores: [CGFloat]
    ) -> RecognitionResult? {
        guard let top = classifications.first else { return nil }
        let rawTopLetter = top.identifier
        let calibratedTopConfidence = calibrator.calibrate(
            rawConfidence: CGFloat(top.confidence),
            predictedLetter: rawTopLetter,
            expectedLetter: expectedLetter,
            historicalFormScores: historicalFormScores
        )
        let topThree: [RecognitionResult.TopCandidate] = classifications
            .prefix(3)
            .map { obs in
                let conf = calibrator.calibrate(
                    rawConfidence: CGFloat(obs.confidence),
                    predictedLetter: obs.identifier,
                    expectedLetter: expectedLetter,
                    historicalFormScores: historicalFormScores
                )
                return .init(letter: obs.identifier, confidence: conf)
            }

        let isCorrect: Bool
        if let expected = expectedLetter {
            isCorrect = rawTopLetter.caseInsensitiveCompare(expected) == .orderedSame
        } else {
            isCorrect = false
        }

        return RecognitionResult(
            predictedLetter: rawTopLetter,
            confidence: calibratedTopConfidence,
            rawConfidence: CGFloat(top.confidence),
            topThree: topThree,
            isCorrect: isCorrect
        )
    }

    // MARK: - Image rendering

    /// Rasterize the child's stroke into a 40×40 grayscale CGImage
    /// matching the training data distribution: black background, white
    /// strokes, centered with a small padding, line width 2.5 at model
    /// resolution. Returns nil when the path has no extent.
    static func renderToImage(points: [CGPoint],
                               strokeStartIndices: [Int] = [],
                               canvasSize: CGSize) -> CGImage? {
        guard points.count >= 2 else { return nil }
        let targetSize = CGSize(width: 40, height: 40)

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let boxW = max(maxX - minX, 1)
        let boxH = max(maxY - minY, 1)

        // 10% padding on each side → scale to fit 80% of 40×40 = 32 px
        let padding: CGFloat = 4
        let drawSize = targetSize.width - 2 * padding
        let scale = min(drawSize / boxW, drawSize / boxH)
        let offsetX = (targetSize.width  - boxW * scale) / 2
        let offsetY = (targetSize.height - boxH * scale) / 2

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Black background (0 in grayscale).
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: targetSize))

        // Flip Y so our top-left-origin points draw upright into the
        // bottom-left-origin CGContext. Without this the letter would
        // render upside down and the model would classify mirror glyphs.
        context.translateBy(x: 0, y: targetSize.height)
        context.scaleBy(x: 1, y: -1)

        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Break the polyline at every stroke-start index so multi-
        // stroke letters render as N disjoint polylines instead of
        // one zig-zag with phantom diagonals across the lifts. The
        // implicit start at index 0 is added to the front of the
        // breaks list so the loop body is uniform.
        let breaks = ([0] + strokeStartIndices.filter { $0 > 0 && $0 < points.count })
            .sorted()
        let path = CGMutablePath()
        for (b, breakIdx) in breaks.enumerated() {
            let endIdx = (b + 1 < breaks.count) ? breaks[b + 1] : points.count
            guard breakIdx < endIdx else { continue }
            let first = points[breakIdx]
            path.move(to: CGPoint(
                x: offsetX + (first.x - minX) * scale,
                y: offsetY + (first.y - minY) * scale
            ))
            for i in (breakIdx + 1)..<endIdx {
                let p = points[i]
                path.addLine(to: CGPoint(
                    x: offsetX + (p.x - minX) * scale,
                    y: offsetY + (p.y - minY) * scale
                ))
            }
        }
        context.addPath(path)
        context.strokePath()

        return context.makeImage()
    }
}

// MARK: - Test stub

/// In-memory recognizer used by unit tests and previews. Returns a
/// pre-configured result regardless of input, or `nil` to simulate a
/// missing model.
struct StubLetterRecognizer: LetterRecognizerProtocol {
    let result: RecognitionResult?

    init(result: RecognitionResult? = nil) {
        self.result = result
    }

    /// Convenience: build a recognizer that always reports the given
    /// letter as correct with the given confidence.
    static func alwaysReturn(
        predicted: String,
        confidence: CGFloat,
        isCorrect: Bool = true
    ) -> StubLetterRecognizer {
        StubLetterRecognizer(result: RecognitionResult(
            predictedLetter: predicted,
            confidence: confidence,
            topThree: [.init(letter: predicted, confidence: confidence)],
            isCorrect: isCorrect
        ))
    }

    func recognize(points: [CGPoint],
                   strokeStartIndices: [Int],
                   canvasSize: CGSize,
                   expectedLetter: String?,
                   historicalFormScores: [CGFloat]) async -> RecognitionResult? {
        // historicalFormScores + strokeStartIndices intentionally
        // ignored: the stub returns its pre-configured result
        // regardless of input.
        _ = historicalFormScores
        _ = strokeStartIndices
        // Truthfulness check (DEBUG only). The pre-configured
        // `result.isCorrect` should match
        // `result.predictedLetter == expectedLetter` when the caller
        // supplied an expectation; otherwise the test is asserting
        // against an inconsistent stub state and any pass/fail signal
        // it produces is suspect. Production builds skip this check
        // so the stub stays a zero-cost no-op outside tests.
        #if DEBUG
        if let result, let expected = expectedLetter {
            let actuallyCorrect =
                result.predictedLetter.caseInsensitiveCompare(expected) == .orderedSame
            assert(
                result.isCorrect == actuallyCorrect,
                "StubLetterRecognizer: result.isCorrect (\(result.isCorrect)) " +
                "contradicts predicted='\(result.predictedLetter)' vs " +
                "expected='\(expected)'. Either fix the stub setup or use " +
                "alwaysReturn(predicted:confidence:isCorrect:) honestly."
            )
        }
        #endif
        return result
    }

    func isModelAvailable() async -> Bool { result != nil }
}

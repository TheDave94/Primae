// LetterRecognizer.swift
// BuchstabenNative
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

// MARK: - Result type

/// Outcome of a single recognition call.
struct RecognitionResult: Equatable, Sendable {
    /// Top-1 label returned by the model.
    let predictedLetter: String
    /// Calibrated confidence (0–1) for the top label.
    let confidence: CGFloat
    /// Top-3 labels with calibrated confidences, descending.
    let topThree: [TopCandidate]
    /// True when `predictedLetter` matches `expectedLetter` case-insensitively.
    /// For freeform mode (no expectation), this is always `false`.
    let isCorrect: Bool

    struct TopCandidate: Equatable, Sendable {
        let letter: String
        let confidence: CGFloat
    }
}

// MARK: - Protocol

/// Async recognition seam. Swap `StubLetterRecognizer` in tests.
protocol LetterRecognizerProtocol: Sendable {
    func recognize(points: [CGPoint],
                   canvasSize: CGSize,
                   expectedLetter: String?) async -> RecognitionResult?
    /// Whether the recognizer's backing model is actually loaded and
    /// ready for inference. `false` means every call to `recognize`
    /// will return `nil`; the UI uses this to distinguish "model
    /// missing" from "model said no" and show a diagnostic banner.
    func isModelAvailable() async -> Bool
}

// MARK: - CoreML-backed recognizer

private let recognizerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BuchstabenNative",
    category: "LetterRecognizer"
)

/// Production recognizer backed by `GermanLetterRecognizer.mlpackage`.
///
/// The model is loaded lazily on first `recognize(…)` call so app startup
/// doesn't pay the Vision framework warm-up cost. If the model file is
/// missing or fails to load, the recognizer logs a warning and every
/// subsequent call returns `nil` — the app falls back to Fréchet-only
/// scoring gracefully.
final class CoreMLLetterRecognizer: LetterRecognizerProtocol, @unchecked Sendable {

    // MARK: Static model cache

    /// nonisolated(unsafe) because Vision's model handles are expensive to
    /// load (~50 ms) and are safe to share across threads after
    /// construction. Guarded by `loadLock` on first touch.
    private nonisolated(unsafe) static var sharedModel: VNCoreMLModel?
    private nonisolated(unsafe) static var didAttemptLoad = false
    private static let loadLock = NSLock()

    private let calibrator: ConfidenceCalibrator

    // MARK: Init

    init(calibrator: ConfidenceCalibrator = ConfidenceCalibrator()) {
        self.calibrator = calibrator
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
                   canvasSize: CGSize,
                   expectedLetter: String?) async -> RecognitionResult? {
        guard points.count >= 2, canvasSize.width > 0, canvasSize.height > 0 else {
            return nil
        }
        let expected = expectedLetter
        let calibratorCopy = calibrator
        // The entire hot path — model load on first call, 40×40 CGContext
        // rasterization, VNImageRequestHandler.perform — is CPU-heavy and
        // must NOT execute on the MainActor. A detached Task runs on the
        // cooperative thread pool and does not inherit the caller's
        // isolation, so every synchronous call inside happens off-main.
        return await Task.detached(priority: .userInitiated) {
            guard let model = Self.loadModelIfNeeded() else { return nil }
            guard let image = Self.renderToImage(points: points, canvasSize: canvasSize) else {
                return nil
            }
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .centerCrop
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                let classifications = request.results as? [VNClassificationObservation] ?? []
                return Self.makeResult(
                    from: classifications,
                    expectedLetter: expected,
                    calibrator: calibratorCopy
                )
            } catch {
                recognizerLogger.warning("Vision request failed: \(error.localizedDescription)")
                return nil
            }
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
            let name = "BuchstabenNative_BuchstabenNative"
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

    private static func makeResult(
        from classifications: [VNClassificationObservation],
        expectedLetter: String?,
        calibrator: ConfidenceCalibrator
    ) -> RecognitionResult? {
        guard let top = classifications.first else { return nil }
        let rawTopLetter = top.identifier
        let calibratedTopConfidence = calibrator.calibrate(
            rawConfidence: CGFloat(top.confidence),
            predictedLetter: rawTopLetter,
            expectedLetter: expectedLetter
        )
        let topThree: [RecognitionResult.TopCandidate] = classifications
            .prefix(3)
            .map { obs in
                let conf = calibrator.calibrate(
                    rawConfidence: CGFloat(obs.confidence),
                    predictedLetter: obs.identifier,
                    expectedLetter: expectedLetter
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
            topThree: topThree,
            isCorrect: isCorrect
        )
    }

    // MARK: - Image rendering

    /// Rasterize the child's stroke into a 40×40 grayscale CGImage
    /// matching the training data distribution: black background, white
    /// strokes, centered with a small padding, line width 2.5 at model
    /// resolution. Returns nil when the path has no extent.
    static func renderToImage(points: [CGPoint], canvasSize: CGSize) -> CGImage? {
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

        let path = CGMutablePath()
        let first = points[0]
        path.move(to: CGPoint(
            x: offsetX + (first.x - minX) * scale,
            y: offsetY + (first.y - minY) * scale
        ))
        for p in points.dropFirst() {
            path.addLine(to: CGPoint(
                x: offsetX + (p.x - minX) * scale,
                y: offsetY + (p.y - minY) * scale
            ))
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
                   canvasSize: CGSize,
                   expectedLetter: String?) async -> RecognitionResult? {
        result
    }

    func isModelAvailable() async -> Bool { result != nil }
}

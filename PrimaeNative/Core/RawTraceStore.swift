// RawTraceStore.swift
// PrimaeNative
//
// Per-trial raw freeWrite traces — points + timestamps + forces + stroke
// breaks — captured at phase exit BEFORE the buffer clears on the next
// letter load. Re-analysis insurance against the unvalidated
// Schreibmotorik scorer (C1): any future metric can be recomputed from
// the raw trace, which is otherwise discarded forever.
//
// Deliberately a SEPARATE store from ParentDashboardStore: that snapshot
// is re-encoded on the main actor on every persist and is designed to
// stay <100 KB. Raw traces are large, cold, export-only data that must
// not bloat that hot path. Records link to their trace by
// `PhaseSessionRecord.rawTraceID`.

import CoreGraphics
import Foundation

/// One freeWrite trial's raw captured trace. The normalised `path` is
/// intentionally NOT stored — it's redundant (`points[i] / canvasSize`)
/// and reconstructable offline, so `points` + `canvasSize` is lossless
/// and smaller.
struct RawTrace: Codable, Equatable, Identifiable {
    let id: UUID
    let letter: String
    let recordedAt: Date
    /// Canvas-space sample points (one per touch sample).
    let points: [CGPoint]
    /// `CACurrentMediaTime()` per point.
    let timestamps: [CFTimeInterval]
    /// Digitiser force per point (0 for finger / no pencil data).
    let forces: [CGFloat]
    /// Indices into `points` where a fresh stroke begins after a lift.
    let strokeStartIndices: [Int]
    /// Canvas size at capture — lets `points` be re-normalised to 0–1
    /// offline, losslessly recovering the normalised path.
    let canvasSize: CGSize
    /// The reference the trial was scored against, exactly as the scorer
    /// saw it: the bundle's bbox-relative strokes mapped through the
    /// rendered glyph rect into the SAME canvas-normalised space
    /// `points / canvasSize` yields (2026-09-04). Without it a trace could
    /// only be re-scored by re-running the app's CoreText glyph layout for
    /// that canvas size — the offline re-analysis the thesis promises
    /// (Ch.3, Ch.6) was not possible from the export alone. Optional so
    /// traces written before this field decode unchanged.
    var referenceStrokes: LetterStrokes? = nil
}

extension RawTrace {
    /// Whether any sample, force, timestamp or the canvas size is NaN or
    /// infinite (R-053).
    var hasNonFiniteValue: Bool {
        !canvasSize.width.isFinite || !canvasSize.height.isFinite
            || points.contains { !$0.x.isFinite || !$0.y.isFinite }
            || forces.contains { !$0.isFinite }
            || timestamps.contains { !$0.isFinite }
    }
}

@MainActor
protocol RawTraceStoring {
    /// All stored traces, oldest first.
    var traces: [RawTrace] { get }
    /// Append one trace. Call BEFORE writing the linking
    /// `PhaseSessionRecord` so a crash leaves at most an orphan trace,
    /// never a record pointing at a missing trace.
    func append(_ trace: RawTrace)
    func reset()
    /// Await any pending background write.
    func flush() async
}

extension RawTraceStoring {
    func flush() async {}
}

/// JSON-backed implementation. Mirrors `JSONParentDashboardStore`: encode
/// on main, write off main with cancel-and-replace coalescing.
final class JSONRawTraceStore: RawTraceStoring {

    private let fileURL: URL
    private(set) var traces: [RawTrace]
    private var pendingSave: Task<Void, Never>?

    /// Hard ceiling — bounds the file if a device is reused without a
    /// reset. One freeWrite trial per letter, so ~500 is many sessions of
    /// headroom; the new-participant reset clears it between children.
    private static let cap = 500

    /// See `JSONProgressStore.failureCenter` / `.writeRefusal`.
    private let failureCenter: PersistenceFailureCenter
    private(set) var writeRefusal: String?

    init(fileURL: URL? = nil, failureCenter: PersistenceFailureCenter = .shared) {
        self.failureCenter = failureCenter
        if let url = fileURL {
            self.fileURL = url
        } else {
            // See ProgressStore.init for the `??` fallback rationale.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("PrimaeNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("rawtraces.json")
        }
        let loaded = Self.load(from: self.fileURL, center: failureCenter)
        self.traces = loaded.value ?? []
        self.writeRefusal = loaded.writeRefusal
    }

    func append(_ trace: RawTrace) {
        // Raw data stays raw: a non-finite sample is KEPT (StoreCoding
        // writes it as a token, so it can no longer stop every later save,
        // R-053) and listed for the proctor.
        if trace.hasNonFiniteValue {
            failureCenter.reportNotice(store: "RawTraceStore",
                                       message: "trace \(trace.id.uuidString.prefix(8)) (\(trace.letter)) carries non-finite samples — kept as recorded")
        }
        traces.append(trace)
        if traces.count > Self.cap {
            // Loud (R-056, audit 2026-10-13): an evicted trace leaves its
            // record's rawTraceID dangling — the invariant above — so the
            // eviction is listed for the proctor, never silent.
            let evicted = traces.count - Self.cap
            traces.removeFirst(evicted)
            failureCenter.reportNotice(store: "RawTraceStore",
                                       message: "cap \(Self.cap) reached — \(evicted) oldest trace(s) evicted; their records now point at no trace")
        }
        persist()
    }

    func reset() {
        traces = []
        persist()
    }

    func flush() async { await pendingSave?.value }

    // MARK: Private

    private func persist() {
        // Encode on main, write off main. See ParentDashboardStore.persist
        // for the cancel-and-replace coalescing rationale.
        guard writeRefusal == nil else {
            storePersistenceLogger.error("RawTraceStore write refused — the file on disk is kept: \(self.writeRefusal ?? "", privacy: .public)")
            return
        }
        guard let data = StoreCoding.encode(traces, store: "RawTraceStore", center: failureCenter) else { return }
        let url = fileURL
        let center = failureCenter
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Loud now (2026-09-14) — see PersistenceFailureCenter.
                storePersistenceLogger.warning(
                    "RawTraceStore disk write failed at \(url.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                center.reportFailure(store: "RawTraceStore", error: error)
            }
        }
    }

    private static func load(from url: URL, center: PersistenceFailureCenter) -> StoreLoad<[RawTrace]> {
        // Missing / unreadable / undecodable: see `StoreFileQuarantine.load`
        // (R-054). Element-wise: one malformed trace must not cost the
        // rest (see LossyArray).
        var dropped = 0
        let loaded = StoreFileQuarantine.load(
            url, store: "RawTraceStore", center: center,
            decode: { data -> [RawTrace] in
                let lossy = try StoreCoding.decoder().decode(LossyArray<RawTrace>.self, from: data)
                dropped = lossy.droppedCount
                return lossy.elements
            })
        if dropped > 0 {
            // The next persist rewrites the file without them — keep the
            // original bytes and tell the proctor (R-055).
            let copy = StoreFileQuarantine.preserveCopy(url)
            center.reportNotice(store: "RawTraceStore",
                                message: "dropped \(dropped) undecodable trace(s) at load, \(loaded.value?.count ?? 0) kept; original copied to \(copy?.lastPathComponent ?? "— copy FAILED")")
        }
        return loaded
    }
}

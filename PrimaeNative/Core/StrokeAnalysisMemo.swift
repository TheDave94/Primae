// StrokeAnalysisMemo.swift
// PrimaeNative
//
// The stroke analysis (`StrokeProcessScorer.analyze`) of a free-writing
// production, computed OFF the main actor while the 2 s quiet window runs,
// and read back on the main actor when the window closes (T1R, 2026-11-25).
//
// Measured on the iPad (Debug-Study): the assignment search cost ~230 ms
// per call on the main actor, and a completion ran it twice (the
// assessment, then the r25 attempt check) - the 553 ms hang at the bubble
// pause's start. In Release-Study it is ~10 ms per call.
//
// The memo is keyed by the EXACT inputs of `analyze` and holds its exact
// output, so a hit returns what the computation would: scoring is
// unchanged, only where it runs. A miss (the prefetch has not finished, or
// a route scores without a lift, such as the proctor's unload) computes on
// the caller's actor as before.

import CoreGraphics
import Foundation

nonisolated final class StrokeAnalysisMemo: @unchecked Sendable {
    static let shared = StrokeAnalysisMemo()

    /// The exact inputs of one analysis.
    struct Key: Equatable, Sendable {
        let points: [CGPoint]
        let strokeStartIndices: [Int]
        let reference: LetterStrokes
        let shearLimitDegrees: CGFloat
    }

    /// One analysis' output (nil is a valid output: nothing comparable).
    struct Entry: Sendable {
        let measures: StrokeProcessMeasures?
    }

    /// Entries kept: the current production's, and a few before it.
    static let capacity = 4

    private let lock = NSLock()
    private var entries: [(key: Key, entry: Entry)] = []

    func lookup(_ key: Key) -> Entry? {
        lock.withLock { entries.last(where: { $0.key == key })?.entry }
    }

    func store(_ key: Key, _ measures: StrokeProcessMeasures?) {
        lock.withLock {
            entries.removeAll { $0.key == key }
            entries.append((key, Entry(measures: measures)))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
    }

    /// Analyse a single-cell production off the main actor, normalised the
    /// way the assessment and the attempt check normalise it (the canvas
    /// frame), and keep the result. The task returns the key it analysed,
    /// so a caller (a test) can wait for it and check the inputs.
    @discardableResult
    func prefetch(points: [CGPoint], strokeStartIndices: [Int], reference: LetterStrokes,
                  frame: CGRect) -> Task<Key, Never> {
        Task.detached(priority: .userInitiated) {
            let iso = StrokeProcessScorer.heightNormalised(points: points, reference: reference, frame: frame)
            _ = StrokeProcessScorer.analyze(points: iso.points, strokeStartIndices: strokeStartIndices,
                                            reference: iso.reference)
            return Key(points: iso.points, strokeStartIndices: strokeStartIndices, reference: iso.reference,
                       shearLimitDegrees: StrokeProcessScorer.shearLimitDegrees)
        }
    }
}

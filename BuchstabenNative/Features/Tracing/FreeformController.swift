// FreeformController.swift
// BuchstabenNative
//
// Owns every piece of state the freeform writing mode needs:
// the active sub-mode (letter / word), the in-progress drawing buffers,
// the recognition request / result lifecycle, and the debounce task
// that gates multi-stroke recognition.
//
// Extracted from TracingViewModel during the W8 God-object cleanup.
// The VM still drives the *methods* — entering / leaving freeform,
// running CoreML, recording completions in the dashboard — because
// those touch VM-only collaborators (audio, recognizer, speech,
// progressStore). The controller exists to put the freeform fields
// in one Observable container so a view-model audit can reason
// about them without scrolling through 300 lines of unrelated
// guided-mode state.

import CoreGraphics
import Foundation

@MainActor
@Observable
final class FreeformController {

    // MARK: - Mode

    /// Whether the canvas is in guided tracing or freeform mode.
    /// Driven by `enterFreeformMode` / `exitFreeformMode` on the VM.
    var writingMode: WritingMode = .guided
    /// Letter or word sub-mode within freeform. The VM resets the
    /// canvas when this changes via the picker, but it can also be
    /// set directly by the picker so word-mode entry stays cheap.
    var freeformSubMode: FreeformSubMode = .letter
    /// Active target word in `.word` sub-mode. nil otherwise.
    var freeformTargetWord: FreeformWord?

    // MARK: - Drawing buffers

    /// Canvas-space points across all completed strokes.
    var freeformPoints: [CGPoint] = []
    /// Per-stroke point counts so word-segmentation can recover the
    /// original stroke boundaries when bucketing by x-centroid.
    var freeformStrokeSizes: [Int] = []
    /// Live in-progress stroke. Cleared on every endTouch; the
    /// committed portion is appended to `freeformPoints`.
    var freeformActivePath: [CGPoint] = []

    // MARK: - Recognition state

    /// Slot-aligned word results. Length always equals target-word
    /// length; nil entries mean "no strokes fell into that bucket".
    var freeformWordResultSlots: [RecognitionResult?] = []
    /// Compacted word results (no nils). Convenience for callers
    /// that don't care about empty slots.
    var freeformWordResults: [RecognitionResult] = []
    /// True while the recognition debounce window is counting down.
    var isWaitingForRecognition: Bool = false
    /// True while CoreML inference is running async.
    var isRecognizing: Bool = false
    /// Latest size of the freeform canvas — captured per touch so
    /// recognition uses the same dimensions the strokes were drawn at.
    var freeformCanvasSize: CGSize = .zero
    /// Set to true once a recognition call has completed (regardless
    /// of success). Distinguishes "still thinking" from "finished but
    /// could not recognise".
    var hasRecognitionCompleted: Bool = false
    /// Whether the CoreML model is loaded and ready. nil = not probed.
    /// UI surfaces a "KI-Modell nicht verfügbar" banner on false.
    var isRecognitionModelAvailable: Bool? = nil
    /// True while a model availability probe Task is in flight. Prevents
    /// concurrent probes from rapid mode-toggle gestures: without this
    /// gate the value-only `isRecognitionModelAvailable == nil` check has
    /// a window between dispatch and result where a second probe sneaks
    /// in, redundantly loading the ML model. Reset to false in the probe
    /// completion handler.
    var isProbingModel: Bool = false
    /// Form-accuracy score from the last freeform recognition (0–1),
    /// computed from the child's path against the recognised letter's
    /// reference glyph. nil when the recognised letter has no bundle
    /// reference for the active script, or before the first call.
    var lastFreeformFormScore: CGFloat? = nil

    /// How long to wait after the last pen-lift before recognising in
    /// `.letter` sub-mode. 1.2 s is a comfortable window for a
    /// 5-year-old finishing the horizontal bar of an "A".
    var freeformRecognitionDelay: TimeInterval = 1.2
    /// Active debounce task. Cancelled by every new stroke in
    /// `.letter` sub-mode and by every leave / enter / clear cycle.
    var pendingRecognitionTask: Task<Void, Never>?

    // MARK: - Buffer maintenance

    /// Wipe all drawing buffers + recognition state without touching
    /// `writingMode` / `freeformSubMode` / `freeformTargetWord`. The
    /// VM calls this from `clearFreeformCanvas`, mode switches, and
    /// after the "Nochmal" button.
    func clearBuffers() {
        pendingRecognitionTask?.cancel()
        pendingRecognitionTask = nil
        isWaitingForRecognition = false
        freeformPoints.removeAll(keepingCapacity: true)
        freeformStrokeSizes.removeAll(keepingCapacity: true)
        freeformActivePath.removeAll(keepingCapacity: true)
        freeformWordResults.removeAll(keepingCapacity: true)
        freeformWordResultSlots.removeAll(keepingCapacity: true)
        hasRecognitionCompleted = false
        lastFreeformFormScore = nil
    }
}

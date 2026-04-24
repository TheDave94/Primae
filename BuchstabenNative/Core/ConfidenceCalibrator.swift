// ConfidenceCalibrator.swift
// BuchstabenNative
//
// Post-processing shim between raw CoreML softmax probabilities and the
// confidence values the UI feeds into its 0.4 / 0.7 feedback thresholds.
//
// Two adjustments:
// 1. Confusable-pair letters (C/c, O/o, S/s, …) are notoriously brittle in
//    40×40 grayscale CNNs. Require a higher raw confidence before we call
//    a prediction "confident" — 15% headroom.
// 2. Children who consistently draw a given letter well (high historical
//    Fréchet form score) deserve a modest 10% boost; novices do not.

import CoreGraphics
import Foundation

/// Adjusts raw GermanLetterRecognizer confidences to reduce false
/// positives on visually-similar letter pairs and reward demonstrated
/// historical accuracy.
struct ConfidenceCalibrator: Sendable {

    // MARK: - Public knobs

    /// Penalty applied to the raw confidence when the prediction is part
    /// of a confusable pair. 0.15 means "require an extra 15% on top of
    /// the raw model confidence before we consider the prediction
    /// confident." Calibrated empirically to push C vs O confusions
    /// below the 0.7 threshold that triggers the green "correct" badge.
    var confusablePenalty: CGFloat

    /// Multiplicative boost applied when the child has a strong history
    /// of writing the expected letter (mean form score ≥ `historyStrongThreshold`).
    /// 0.10 = a 10% bump. The boost is CAPPED at 1.0 so a calibrated
    /// confidence never exceeds that ceiling.
    var historyBoost: CGFloat

    /// Mean historical form-accuracy required before the history boost
    /// applies. Set deliberately high (0.80) so a child who has merely
    /// traced the letter once or twice doesn't get a free confidence
    /// uplift.
    var historyStrongThreshold: CGFloat

    /// Minimum number of history samples required before the history
    /// boost is considered — below this we don't trust the signal.
    var minimumHistorySamples: Int

    /// Letter pairs that the model regularly mixes up. Grouped by base
    /// letter so both upper and lower case versions share the same
    /// penalty — this matches the thesis dataset where training the CNN
    /// on all 53 classes means the canonical confusables include both
    /// cases.
    var confusableLetters: Set<String>

    // MARK: - Init

    init(
        confusablePenalty: CGFloat = 0.15,
        historyBoost: CGFloat = 0.10,
        historyStrongThreshold: CGFloat = 0.80,
        minimumHistorySamples: Int = 5,
        confusableLetters: Set<String> = Self.defaultConfusables
    ) {
        self.confusablePenalty      = confusablePenalty
        self.historyBoost           = historyBoost
        self.historyStrongThreshold = historyStrongThreshold
        self.minimumHistorySamples  = minimumHistorySamples
        self.confusableLetters      = confusableLetters
    }

    /// Default confusable set. Chosen from the spec: C/c, O/o, S/s, V/v,
    /// W/w, X/x, Z/z, P/p, U/u, K/k. Both cases in the set because the
    /// model's output classes are case-specific.
    static let defaultConfusables: Set<String> = [
        "C", "c", "O", "o", "S", "s", "V", "v", "W", "w",
        "X", "x", "Z", "z", "P", "p", "U", "u", "K", "k"
    ]

    // MARK: - Calibration

    /// Calibrate a raw model confidence. History is optional — leave
    /// `historicalFormScores` empty or nil to skip the boost branch.
    ///
    /// - Parameters:
    ///   - rawConfidence: Model-reported probability (0–1).
    ///   - predictedLetter: The class the model emitted (e.g. "C", "o").
    ///   - expectedLetter: The letter the child was asked to write.
    ///     Passed so extensions can apply expectation-aware corrections
    ///     (currently unused — kept in the signature for forward
    ///     compatibility with per-letter calibration tables).
    ///   - historicalFormScores: Past freeWrite form-accuracy samples
    ///     for `expectedLetter`, 0–1. Oldest-first, any length.
    /// - Returns: Calibrated confidence in 0…1.
    func calibrate(
        rawConfidence: CGFloat,
        predictedLetter: String,
        expectedLetter: String? = nil,
        historicalFormScores: [CGFloat] = []
    ) -> CGFloat {
        var confidence = max(0, min(1, rawConfidence))

        if confusableLetters.contains(predictedLetter) {
            confidence = max(0, confidence - confusablePenalty)
        }

        if historicalFormScores.count >= minimumHistorySamples {
            let mean = historicalFormScores.reduce(0, +) / CGFloat(historicalFormScores.count)
            if mean >= historyStrongThreshold {
                confidence = min(1, confidence * (1 + historyBoost))
            }
        }

        return confidence
    }
}

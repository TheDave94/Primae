import Foundation
import CoreGraphics

// MARK: - Difficulty tiers

enum DifficultyTier: Int, Codable, Comparable, CaseIterable, Equatable {
    case easy = 0
    case standard = 1
    case strict = 2

    static func < (lhs: DifficultyTier, rhs: DifficultyTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Checkpoint radius multiplier relative to the definition's base radius.
    var radiusMultiplier: CGFloat {
        switch self {
        case .easy:     return 1.5
        case .standard: return 1.0
        case .strict:   return 0.65
        }
    }
}

// MARK: - Session sample

struct AdaptationSample: Codable, Equatable {
    let letter: String
    let accuracy: CGFloat       // 0–1
    let completionTime: TimeInterval  // seconds; 0 = timed out / incomplete
}

// MARK: - Protocol

protocol AdaptationPolicy {
    /// Current tier based on accumulated history.
    var currentTier: DifficultyTier { get }
    /// Record a completed session sample and optionally update tier.
    mutating func record(_ sample: AdaptationSample)
    /// Reset all history and return to default tier.
    mutating func reset()
}

// MARK: - Fixed policy (for tests / locked difficulty)

struct FixedAdaptationPolicy: AdaptationPolicy {
    let currentTier: DifficultyTier
    mutating func record(_ sample: AdaptationSample) {}
    mutating func reset() {}
}

// MARK: - Moving-average policy

/// Computes a rolling accuracy and time score over the last `windowSize` samples.
/// Promotion/demotion requires crossing the threshold for `hysteresisCount`
/// consecutive evaluations to prevent rapid tier flipping.
struct MovingAverageAdaptationPolicy: AdaptationPolicy {

    let windowSize: Int
    let hysteresisCount: Int
    let promotionAccuracyThreshold: CGFloat   // above → promote candidate
    let demotionAccuracyThreshold: CGFloat    // below → demote candidate

    private(set) var currentTier: DifficultyTier
    private(set) var samples: [AdaptationSample] = []
    private var consecutivePromotionCandidates = 0
    private var consecutiveDemotionCandidates = 0

    init(
        windowSize: Int = 10,
        hysteresisCount: Int = 3,
        promotionAccuracyThreshold: CGFloat = 0.85,
        demotionAccuracyThreshold: CGFloat = 0.55,
        initialTier: DifficultyTier = .standard
    ) {
        self.windowSize = max(1, windowSize)
        self.hysteresisCount = max(1, hysteresisCount)
        self.promotionAccuracyThreshold = promotionAccuracyThreshold
        self.demotionAccuracyThreshold = demotionAccuracyThreshold
        self.currentTier = initialTier
    }

    var windowAccuracy: CGFloat {
        guard !samples.isEmpty else { return 0 }
        let window = Array(samples.suffix(windowSize))
        return window.map(\.accuracy).reduce(0, +) / CGFloat(window.count)
    }

    mutating func record(_ sample: AdaptationSample) {
        samples.append(sample)
        evaluateTier()
    }

    mutating func reset() {
        samples = []
        consecutivePromotionCandidates = 0
        consecutiveDemotionCandidates = 0
        currentTier = .standard
    }

    // MARK: - Private

    private mutating func evaluateTier() {
        guard samples.count >= windowSize else { return }
        let avg = windowAccuracy

        if avg >= promotionAccuracyThreshold {
            consecutivePromotionCandidates += 1
            consecutiveDemotionCandidates = 0
        } else if avg <= demotionAccuracyThreshold {
            consecutiveDemotionCandidates += 1
            consecutivePromotionCandidates = 0
        } else {
            consecutivePromotionCandidates = 0
            consecutiveDemotionCandidates = 0
        }

        if consecutivePromotionCandidates >= hysteresisCount, currentTier < .strict {
            currentTier = DifficultyTier(rawValue: currentTier.rawValue + 1) ?? currentTier
            consecutivePromotionCandidates = 0
        } else if consecutiveDemotionCandidates >= hysteresisCount, currentTier > .easy {
            currentTier = DifficultyTier(rawValue: currentTier.rawValue - 1) ?? currentTier
            consecutiveDemotionCandidates = 0
        }
    }
}

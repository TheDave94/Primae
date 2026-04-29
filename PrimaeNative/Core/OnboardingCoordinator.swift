import Foundation

// MARK: - Onboarding steps

enum OnboardingStep: String, Codable, CaseIterable, Equatable {
    case welcome
    case traceDemo        // phase 1 — observe (Anschauen) animated stroke demo
    case directDemo       // phase 2 — direct (Richtung lernen) numbered-dot tap demo
    case guidedDemo       // phase 3 — guided (Nachspuren) finger-trace demo
    case freeWriteDemo    // phase 4 — freeWrite (Selbst schreiben) intro
    case rewardIntro      // streak/reward explanation
    case complete
}

// MARK: - U4 (ROADMAP) — onboarding length variants for A/B comparison

/// Two onboarding length variants. The thesis cohort can be split
/// between them to measure first-day engagement / completion-rate
/// against the two flows. The variant the child actually ran is
/// recorded on `OnboardingState.variantUsed` so post-hoc CSV analysis
/// can correlate retention/streak metrics with which onboarding ran.
///
/// `full` is the canonical 7-step flow with one demo per phase plus
/// the reward-system intro.
/// `short` is the compressed 3-step flow: welcome → guided demo → done.
/// The compressed variant skips the per-phase concept demos; parents
/// who want the long version can re-run via "Einführung wiederholen".
enum OnboardingVariant: String, Codable, CaseIterable, Equatable {
    case full
    case short

    /// German display label for the SettingsView picker.
    var displayName: String {
        switch self {
        case .full:  return "Lang (7 Schritte)"
        case .short: return "Kurz (3 Schritte)"
        }
    }

    /// Step list that the OnboardingCoordinator should iterate through
    /// when this variant is active. `complete` is always the terminator.
    var steps: [OnboardingStep] {
        switch self {
        case .full:
            return OnboardingStep.allCases
        case .short:
            return [.welcome, .guidedDemo, .complete]
        }
    }
}

// MARK: - Coordinator state machine

struct OnboardingCoordinator: Equatable {

    private(set) var currentStep: OnboardingStep
    private(set) var completedSteps: Set<OnboardingStep>
    let steps: [OnboardingStep]

    init(steps: [OnboardingStep] = OnboardingStep.allCases) {
        self.steps = steps
        self.currentStep = steps.first ?? .welcome
        self.completedSteps = []
    }

    var isComplete: Bool { currentStep == .complete }
    var canGoBack: Bool {
        guard let idx = steps.firstIndex(of: currentStep) else { return false }
        return idx > 0
    }
    var progress: Double {
        guard steps.count > 1 else { return 1.0 }
        let idx = steps.firstIndex(of: currentStep) ?? 0
        return Double(idx) / Double(steps.count - 1)
    }

    /// Advance to next step. Returns true if advanced, false if already complete.
    @discardableResult
    mutating func advance() -> Bool {
        guard let idx = steps.firstIndex(of: currentStep),
              idx + 1 < steps.count else { return false }
        completedSteps.insert(currentStep)
        currentStep = steps[idx + 1]
        return true
    }

    /// Go back to previous step.
    @discardableResult
    mutating func back() -> Bool {
        guard let idx = steps.firstIndex(of: currentStep), idx > 0 else { return false }
        currentStep = steps[idx - 1]
        return true
    }

    /// Skip directly to complete.
    mutating func skip() {
        steps.forEach { completedSteps.insert($0) }
        completedSteps.remove(.complete)
        currentStep = .complete
    }

    /// Jump to a specific step (e.g. resume from persisted state).
    mutating func resume(at step: OnboardingStep) {
        guard steps.contains(step) else { return }
        currentStep = step
    }
}

// MARK: - First-launch detection store

protocol OnboardingStoring {
    var hasCompletedOnboarding: Bool { get }
    var savedStep: OnboardingStep? { get }
    /// U4 (ROADMAP): which OnboardingVariant ran for this install. Read
    /// on first complete and never overwritten so a post-hoc CSV
    /// analysis can correlate the parent's choice with later
    /// engagement metrics.
    var variantUsed: OnboardingVariant? { get }
    func markComplete(variant: OnboardingVariant)
    func saveProgress(step: OnboardingStep)
    func reset()
    /// Await any pending background disk write. Mirrors the pattern on the
    /// other JSON-backed stores so a future awaited app-suspension flush can
    /// guarantee the onboarding step is durable before the process suspends.
    /// Default no-op for in-memory mocks.
    func flush() async
}

extension OnboardingStoring {
    func flush() async {}
    /// Backward-compat shim for callers that don't pass a variant.
    /// Records as `.full` since that's what the historical 7-step flow was.
    func markComplete() { markComplete(variant: .full) }
    /// Default nil so older mocks compile unchanged.
    var variantUsed: OnboardingVariant? { nil }
}

private struct OnboardingState: Codable {
    var completed: Bool = false
    var savedStepRaw: String? = nil
    /// U4 (ROADMAP): variant the child actually ran. nil for legacy
    /// state files written before the A/B framework landed.
    var variantUsedRaw: String? = nil
}

final class JSONOnboardingStore: OnboardingStoring {

    private let fileURL: URL
    private var state: OnboardingState
    /// Serialised chain of background disk writes. Lets `persist()` return
    /// immediately (no MainActor hitch on every onboarding step change) while
    /// guaranteeing write order. `flush()` awaits any in-flight write.
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = nil) {
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
            self.fileURL = dir.appendingPathComponent("onboarding.json")
        }
        self.state = Self.load(from: self.fileURL) ?? OnboardingState()
    }

    var hasCompletedOnboarding: Bool { state.completed }
    var savedStep: OnboardingStep? {
        guard let raw = state.savedStepRaw else { return nil }
        return OnboardingStep(rawValue: raw)
    }
    var variantUsed: OnboardingVariant? {
        guard let raw = state.variantUsedRaw else { return nil }
        return OnboardingVariant(rawValue: raw)
    }

    func markComplete(variant: OnboardingVariant) {
        state.completed = true
        state.savedStepRaw = nil
        // Only record the variant on the FIRST complete — a re-run
        // ("Einführung wiederholen") can change the variant in the
        // settings, but the original-A/B-assignment shouldn't be
        // overwritten or the post-hoc analysis can't correlate.
        if state.variantUsedRaw == nil {
            state.variantUsedRaw = variant.rawValue
        }
        persist()
    }

    func saveProgress(step: OnboardingStep) {
        state.savedStepRaw = step.rawValue
        persist()
    }

    func reset() {
        state = OnboardingState()
        persist()
    }

    private func persist() {
        // Encode on main, write off main: see ProgressStore.save() for the
        // same pattern and the rationale.
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = fileURL
        // Same coalesce-and-await pattern as the other JSON stores: each
        // call cancels and supersedes the previous pending write since the
        // encoded data is already the full latest copy. Ordering is
        // preserved by awaiting the previous task before this one's write
        // hits the disk.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                storePersistenceLogger.warning(
                    "OnboardingCoordinator disk write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func flush() async {
        await pendingSave?.value
    }

    private static func load(from url: URL) -> OnboardingState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OnboardingState.self, from: data)
    }
}

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
    func markComplete()
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
}

private struct OnboardingState: Codable {
    var completed: Bool = false
    var savedStepRaw: String? = nil
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
            let dir = support.appendingPathComponent("BuchstabenNative", isDirectory: true)
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

    func markComplete() {
        state.completed = true
        state.savedStepRaw = nil
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
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = fileURL
        // Same coalesce-and-await pattern as the other JSON stores: each call
        // cancels and supersedes the previous pending write since `data` is
        // already the full latest snapshot. Ordering is preserved by awaiting
        // the previous task before this one's write hits the disk.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            try? data.write(to: url, options: .atomic)
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

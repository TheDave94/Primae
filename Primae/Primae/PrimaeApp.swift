import SwiftUI
import PrimaeNative

// MARK: - Main entry point

// During XCTest runs the test host bootstraps `TestApp` with an empty
// WindowGroup so AVAudioEngine isn't initialised in the headless
// simulator (it would abort with an RPC timeout / SIGABRT).
@main
struct MainEntryPoint {
    static func main() {
        if NSClassFromString("XCTestCase") != nil {
            // Before anything reads a default: the hosted unit tests get
            // their own preferences domain, never the pilot's (R-052).
            HostedTestIsolation.installIfHostingTests()
            TestApp.main()
        } else {
            PrimaeApp.main()
        }
    }
}

// MARK: - Production app
struct PrimaeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = TracingViewModel()

    /// Stored under `primaeAppearance`: "system" / "light" / "dark".
    @AppStorage(PrimaeAppearance.storageKey) private var appearance: String = "system"

    init() {
        // Register SPM-bundled fonts with CoreText. `UIAppFonts` only
        // covers main-bundle fonts; the SPM resource bundle needs
        // `CTFontManagerRegisterFontsForURLs`. Idempotent.
        PrimaeFonts.registerAll()
        // Pre-create the calibration session-log root so the app
        // appears in the Files app even before the first save lands.
        CalibrationSessionLogger.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            PrimaeNative.MainAppView()
                .environment(vm)
                // Study sessions render the stimulus in light appearance
                // regardless of the parent-area "Erscheinungsbild" pick:
                // dark mode changes the letter's and the ink's colours,
                // and the study configuration is supposed to pin every
                // setting that could vary between children (2026-09-04).
                .preferredColorScheme(vm.studyMode ? .light : PrimaeAppearance.resolve(appearance))
        }
        .onChange(of: scenePhase) { _, newPhase in
            // `.inactive` suspends the session (Control Center, a banner,
            // an app-switcher peek); `.background` also finalises and
            // drains the stores; `.active` resumes. The mapping lives on
            // the view model so it is tested (R-005,
            // `ScenePhaseInterruptionTests`).
            vm.scenePhaseDidChange(to: newPhase)
        }
    }
}

// MARK: - Test host app (empty — avoids AVAudioEngine init)
struct TestApp: App {
    var body: some Scene {
        WindowGroup { }
    }
}

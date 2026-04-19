import SwiftUI
import BuchstabenNative

// MARK: - Main entry point
// During XCTest runs, the test host process bootstraps a TestApp with an
// empty WindowGroup. This prevents AVAudioEngine from being initialised in
// the headless simulator where it would abort with an RPC timeout (SIGABRT).
@main
struct MainEntryPoint {
    static func main() {
        if NSClassFromString("XCTestCase") != nil {
            TestApp.main()
        } else {
            BuchstabenAppMain.main()
        }
    }
}

// MARK: - Production app
struct BuchstabenAppMain: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = TracingViewModel()

    var body: some Scene {
        WindowGroup {
            BuchstabenNative.ContentView()
                .environment(vm)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                vm.appDidBecomeActive()
            case .background, .inactive:
                // appDidEnterBackground is now async — it drains pending JSON
                // store writes after the synchronous state cleanup. Wrap in a
                // Task so iOS's scene-suspension grace window holds the process
                // alive until the awaits resolve, instead of losing a freshly
                // completed letter to a half-flushed write on suspension.
                Task { await vm.appDidEnterBackground() }
            @unknown default:
                Task { await vm.appDidEnterBackground() }
            }
        }
    }
}

// MARK: - Test host app (empty — avoids AVAudioEngine init)
struct TestApp: App {
    var body: some Scene {
        WindowGroup { }
    }
}

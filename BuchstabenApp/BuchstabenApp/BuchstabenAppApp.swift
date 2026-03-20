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
                vm.appDidEnterBackground()
            @unknown default:
                vm.appDidEnterBackground()
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

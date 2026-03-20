import SwiftUI
import BuchstabenNative

@main
struct BuchstabenAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm: TracingViewModel

    init() {
        // Use NullAudio when running under XCTest to prevent AVAudioEngine
        // from crashing in headless simulators (RPC timeout → SIGABRT).
        if NSClassFromString("XCTestCase") != nil {
            _vm = State(initialValue: TracingViewModel(audio: NullAudio()))
        } else {
            _vm = State(initialValue: TracingViewModel())
        }
    }

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

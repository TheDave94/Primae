import SwiftUI
import BuchstabenNative

@main
struct BuchstabenAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    // When running under XCTest, avoid initialising real AVAudioEngine/AVAudioSession
    // which crashes in headless simulator. Tests inject their own stubs via DI anyway.
    @StateObject private var vm: TracingViewModel = {
        if NSClassFromString("XCTestCase") != nil {
            return TracingViewModel(singleTouchCooldownAfterNavigation: 0.18, audio: NullAudio())
        }
        return TracingViewModel()
    }()

    var body: some Scene {
        WindowGroup {
            BuchstabenNative.ContentView()
                .environmentObject(vm)
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

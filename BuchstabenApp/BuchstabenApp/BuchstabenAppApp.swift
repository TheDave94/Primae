import SwiftUI
import BuchstabenNative

@main
struct BuchstabenAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = TracingViewModel()

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

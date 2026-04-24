import SwiftUI

struct BuchstabenNativeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = TracingViewModel()

    var body: some Scene {
        WindowGroup {
            MainAppView()
                .environment(vm)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                vm.appDidBecomeActive()
            case .background, .inactive:
                Task { await vm.appDidEnterBackground() }
            @unknown default:
                Task { await vm.appDidEnterBackground() }
            }
        }
    }
}

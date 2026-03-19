import SwiftUI


struct BuchstabenNativeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = TracingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
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

import SwiftUI

@main
struct BuchstabenNativeApp: App {
    @StateObject private var vm = TracingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
    }
}

import SwiftUI


struct BuchstabenNativeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = TracingViewModel()
    @State private var notificationScheduler = LocalNotificationScheduler()
    @State private var didRequestNotificationPermission = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(vm)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                vm.appDidBecomeActive()
                if !didRequestNotificationPermission {
                    didRequestNotificationPermission = true
                    notificationScheduler.requestPermission { _ in }
                }
                notificationScheduler.scheduleDailyReminder(
                    currentStreak: vm.progressStore.currentStreakDays,
                    onboardingComplete: true
                )
            case .background, .inactive:
                vm.appDidEnterBackground()
            @unknown default:
                vm.appDidEnterBackground()
            }
        }
    }
}

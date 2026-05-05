// Covers the reminder-scheduling side-effect of appDidBecomeActive —
// guards the daily notification refresh path in
// TracingViewModel.appDidBecomeActive against regressions.

import Foundation
import Testing
import UserNotifications
@testable import PrimaeNative

@MainActor
@Suite struct LifecycleReminderTests {

    /// A spy that counts `add(_:)` and `remove*` calls — proxy for
    /// LocalNotificationScheduler.scheduleDailyReminder activity.
    final class SpyNotificationCenter: UserNotificationCenterProtocol {
        private(set) var addCount = 0
        private(set) var removeAllCount = 0
        private(set) var requestAuthCount = 0

        func requestAuthorization(options: UNAuthorizationOptions,
                                   completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
            requestAuthCount += 1
            completionHandler(true, nil)
        }
        func add(_ request: UNNotificationRequest,
                 withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
            addCount += 1
            completionHandler?(nil)
        }
        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            removeAllCount += 1
        }
        func removeAllPendingNotificationRequests() {
            removeAllCount += 1
        }
    }

    @Test("appDidBecomeActive re-schedules the daily reminder once onboarding is done")
    func reminderReschedulesOnResume() {
        let spy = SpyNotificationCenter()
        var deps = TracingDependencies.stub
        deps.notificationScheduler = LocalNotificationScheduler(center: spy)
        let vm = TracingViewModel(deps)
        vm.isOnboardingComplete = true

        let before = spy.addCount
        vm.appDidBecomeActive()
        #expect(spy.addCount > before,
                "appDidBecomeActive should trigger scheduleDailyReminder -> center.add")
    }

    @Test("appDidBecomeActive does NOT schedule when onboarding is incomplete")
    func reminderSkippedDuringOnboarding() {
        let spy = SpyNotificationCenter()
        var deps = TracingDependencies.stub
        deps.notificationScheduler = LocalNotificationScheduler(center: spy)
        let vm = TracingViewModel(deps)
        vm.isOnboardingComplete = false

        let before = spy.addCount
        vm.appDidBecomeActive()
        #expect(spy.addCount == before,
                "No reminder should be scheduled before onboarding completes; got addCount=\(spy.addCount) vs before=\(before)")
    }
}

//  LocalNotificationSchedulerTests.swift
//  BuchstabenNativeTests

import Testing
import UserNotifications
@testable import BuchstabenNative

final class MockNotificationCenter: UserNotificationCenterProtocol {
    var authorizationGranted = true
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []
    private(set) var removeAllCalled = false

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) {
        completionHandler(authorizationGranted, nil)
    }
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request); completionHandler?(nil)
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
    func removeAllPendingNotificationRequests() { removeAllCalled = true }
    func reset() { addedRequests = []; removedIdentifiers = []; removeAllCalled = false }
}

@Suite @MainActor struct QuietHoursTests {
    @Test func nonWrapping_inRange() {
        let qh = QuietHours(startHour: 22, endHour: 8)
        #expect(qh.isQuiet(hour: 23)); #expect(qh.isQuiet(hour: 0)); #expect(qh.isQuiet(hour: 7))
    }
    @Test func nonWrapping_outOfRange() {
        let qh = QuietHours(startHour: 22, endHour: 8)
        #expect(!qh.isQuiet(hour: 9)); #expect(!qh.isQuiet(hour: 17)); #expect(!qh.isQuiet(hour: 21))
    }
    @Test func simpleRange_inRange() {
        let qh = QuietHours(startHour: 13, endHour: 15)
        #expect(qh.isQuiet(hour: 13)); #expect(qh.isQuiet(hour: 14))
    }
    @Test func simpleRange_outOfRange() {
        let qh = QuietHours(startHour: 13, endHour: 15)
        #expect(!qh.isQuiet(hour: 15)); #expect(!qh.isQuiet(hour: 12))
    }
}

@Suite struct DefaultDailyReminderPolicyTests {
    let quietHours = QuietHours(startHour: 21, endHour: 8)
    func makePolicy(hour: Int = 17) -> DefaultDailyReminderPolicy {
        DefaultDailyReminderPolicy(defaultHour: hour, defaultMinute: 0, quietHours: quietHours)
    }

    @Test func onboardingIncomplete_returnsNil() {
        #expect(makePolicy().content(currentStreak: 0, onboardingComplete: false, calendar: .current) == nil)
    }
    @Test func quietHour_returnsNil() {
        #expect(makePolicy(hour: 22).content(currentStreak: 5, onboardingComplete: true, calendar: .current) == nil)
    }
    @Test func streak0_defaultMessage() {
        let c = makePolicy().content(currentStreak: 0, onboardingComplete: true, calendar: .current)
        #expect(c != nil); #expect(c!.body.contains("Buchstaben üben"))
    }
    @Test func streak1_day2Message() {
        let c = makePolicy().content(currentStreak: 1, onboardingComplete: true, calendar: .current)
        #expect(c!.body.contains("Tag 2"))
    }
    @Test func streak3_fireEmoji() {
        let c = makePolicy().content(currentStreak: 3, onboardingComplete: true, calendar: .current)
        #expect(c!.body.contains("3 Tage"))
    }
    @Test func streak7_trophyMessage() {
        let c = makePolicy().content(currentStreak: 7, onboardingComplete: true, calendar: .current)
        #expect(c!.body.contains("7 Tage") || c!.body.contains("Meister"))
    }
    @Test func content_identifier_isDailyPractice() {
        #expect(makePolicy().content(currentStreak: 0, onboardingComplete: true, calendar: .current)?.identifier == "daily_practice_reminder")
    }
    @Test func content_titleIsPrimae() {
        #expect(makePolicy().content(currentStreak: 0, onboardingComplete: true, calendar: .current)?.title == "Primae")
    }
}

@Suite @MainActor struct LocalNotificationSchedulerTests {

    func makeScheduler(mock: MockNotificationCenter, policy: DailyReminderPolicy? = nil) -> LocalNotificationScheduler {
        LocalNotificationScheduler(
            center: mock,
            policy: policy ?? DefaultDailyReminderPolicy(defaultHour: 17, defaultMinute: 0,
                                                          quietHours: QuietHours(startHour: 23, endHour: 6)),
            calendar: .current
        )
    }

    @Test func requestPermission_granted_returnsAuthorized() async {
        let mock = MockNotificationCenter(); mock.authorizationGranted = true
        let scheduler = makeScheduler(mock: mock)
        let status = await scheduler.requestPermission()
        #expect(status == .authorized)
    }

    @Test func requestPermission_denied_returnsDenied() async {
        let mock = MockNotificationCenter(); mock.authorizationGranted = false
        let scheduler = makeScheduler(mock: mock)
        let status = await scheduler.requestPermission()
        #expect(status == .denied)
    }

    @Test func scheduleDailyReminder_addsRequest() {
        let mock = MockNotificationCenter()
        makeScheduler(mock: mock).scheduleDailyReminder(currentStreak: 3, onboardingComplete: true)
        #expect(mock.addedRequests.count == 1)
        #expect(mock.addedRequests.first?.identifier == "daily_practice_reminder")
    }
    @Test func scheduleDailyReminder_removesExistingFirst() {
        let mock = MockNotificationCenter()
        makeScheduler(mock: mock).scheduleDailyReminder(currentStreak: 0, onboardingComplete: true)
        #expect(mock.removedIdentifiers.contains("daily_practice_reminder"))
    }
    @Test func scheduleDailyReminder_onboardingIncomplete_doesNotAdd() {
        let mock = MockNotificationCenter()
        makeScheduler(mock: mock).scheduleDailyReminder(currentStreak: 5, onboardingComplete: false)
        #expect(mock.addedRequests.isEmpty)
    }
    @Test func cancelAllReminders_callsRemoveAll() {
        let mock = MockNotificationCenter()
        makeScheduler(mock: mock).cancelAllReminders()
        #expect(mock.removeAllCalled)
    }
    @Test func cancelReminder_specificIdentifier() {
        let mock = MockNotificationCenter()
        makeScheduler(mock: mock).cancelReminder(identifier: "some_id")
        #expect(mock.removedIdentifiers.contains("some_id"))
    }

    @Test func permissionStatus_updatesAfterRequest() async {
        let mock = MockNotificationCenter(); mock.authorizationGranted = true
        let scheduler = makeScheduler(mock: mock)
        #expect(scheduler.permissionStatus == .notDetermined)
        _ = await scheduler.requestPermission()
        #expect(scheduler.permissionStatus == .authorized)
    }
}

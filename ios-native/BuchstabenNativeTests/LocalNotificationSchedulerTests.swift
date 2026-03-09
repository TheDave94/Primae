//  LocalNotificationSchedulerTests.swift
//  BuchstabenNativeTests

import XCTest
import UserNotifications
@testable import BuchstabenNative

// MARK: - Mock notification center

final class MockNotificationCenter: UserNotificationCenterProtocol {
    var authorizationGranted = true
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []
    private(set) var removeAllCalled = false

    func requestAuthorization(options: UNAuthorizationOptions,
                               completionHandler: @escaping (Bool, Error?) -> Void) {
        completionHandler(authorizationGranted, nil)
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        completionHandler?(nil)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }

    func removeAllPendingNotificationRequests() {
        removeAllCalled = true
    }

    func reset() {
        addedRequests = []
        removedIdentifiers = []
        removeAllCalled = false
    }
}

// MARK: - QuietHours tests

@MainActor
final class QuietHoursTests: XCTestCase {

    func testNonWrapping_inRange() {
        let qh = QuietHours(startHour: 22, endHour: 8)
        XCTAssertTrue(qh.isQuiet(hour: 23))
        XCTAssertTrue(qh.isQuiet(hour: 0))
        XCTAssertTrue(qh.isQuiet(hour: 7))
    }

    func testNonWrapping_outOfRange() {
        let qh = QuietHours(startHour: 22, endHour: 8)
        XCTAssertFalse(qh.isQuiet(hour: 9))
        XCTAssertFalse(qh.isQuiet(hour: 17))
        XCTAssertFalse(qh.isQuiet(hour: 21))
    }

    func testSimpleRange_inRange() {
        let qh = QuietHours(startHour: 13, endHour: 15)
        XCTAssertTrue(qh.isQuiet(hour: 13))
        XCTAssertTrue(qh.isQuiet(hour: 14))
    }

    func testSimpleRange_outOfRange() {
        let qh = QuietHours(startHour: 13, endHour: 15)
        XCTAssertFalse(qh.isQuiet(hour: 15))
        XCTAssertFalse(qh.isQuiet(hour: 12))
    }
}

// MARK: - DefaultDailyReminderPolicy tests

final class DefaultDailyReminderPolicyTests: XCTestCase {

    private let quietHours = QuietHours(startHour: 21, endHour: 8)

    private func makePolicy(hour: Int = 17) -> DefaultDailyReminderPolicy {
        DefaultDailyReminderPolicy(defaultHour: hour, defaultMinute: 0, quietHours: quietHours)
    }

    func testOnboardingIncomplete_returnsNil() {
        let p = makePolicy()
        XCTAssertNil(p.content(currentStreak: 0, onboardingComplete: false, calendar: .current))
    }

    func testQuietHour_returnsNil() {
        let p = makePolicy(hour: 22) // 22 is quiet
        XCTAssertNil(p.content(currentStreak: 5, onboardingComplete: true, calendar: .current))
    }

    func testStreak0_defaultMessage() {
        let p = makePolicy()
        let c = p.content(currentStreak: 0, onboardingComplete: true, calendar: .current)
        XCTAssertNotNil(c)
        XCTAssertTrue(c!.body.contains("Time to practice"))
    }

    func testStreak1_day2Message() {
        let p = makePolicy()
        let c = p.content(currentStreak: 1, onboardingComplete: true, calendar: .current)
        XCTAssertTrue(c!.body.contains("day 2"))
    }

    func testStreak3_fireEmoji() {
        let p = makePolicy()
        let c = p.content(currentStreak: 3, onboardingComplete: true, calendar: .current)
        XCTAssertTrue(c!.body.contains("3-day streak"))
    }

    func testStreak7_trophyMessage() {
        let p = makePolicy()
        let c = p.content(currentStreak: 7, onboardingComplete: true, calendar: .current)
        XCTAssertTrue(c!.body.contains("7-day streak") || c!.body.contains("master"))
    }

    func testContent_identifier_isDailyPractice() {
        let p = makePolicy()
        let c = p.content(currentStreak: 0, onboardingComplete: true, calendar: .current)
        XCTAssertEqual(c?.identifier, "daily_practice_reminder")
    }

    func testContent_titleIsBuchstabenLernen() {
        let p = makePolicy()
        let c = p.content(currentStreak: 0, onboardingComplete: true, calendar: .current)
        XCTAssertEqual(c?.title, "Buchstaben Lernen")
    }
}

// MARK: - LocalNotificationScheduler tests

@MainActor
final class LocalNotificationSchedulerTests: XCTestCase {

    private func makeScheduler(mock: MockNotificationCenter,
                                policy: DailyReminderPolicy? = nil) -> LocalNotificationScheduler {
        LocalNotificationScheduler(
            center: mock,
            policy: policy ?? DefaultDailyReminderPolicy(defaultHour: 17, defaultMinute: 0,
                                                          quietHours: QuietHours(startHour: 23, endHour: 6)),
            calendar: .current
        )
    }

    func testRequestPermission_granted_returnsAuthorized() {
        let mock = MockNotificationCenter()
        mock.authorizationGranted = true
        let scheduler = makeScheduler(mock: mock)
        let exp = expectation(description: "perm")
        scheduler.requestPermission { status in
            XCTAssertEqual(status, .authorized)
            exp.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testRequestPermission_denied_returnsDenied() {
        let mock = MockNotificationCenter()
        mock.authorizationGranted = false
        let scheduler = makeScheduler(mock: mock)
        let exp = expectation(description: "perm")
        scheduler.requestPermission { status in
            XCTAssertEqual(status, .denied)
            exp.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testScheduleDailyReminder_addsRequest() {
        let mock = MockNotificationCenter()
        let scheduler = makeScheduler(mock: mock)
        scheduler.scheduleDailyReminder(currentStreak: 3, onboardingComplete: true)
        XCTAssertEqual(mock.addedRequests.count, 1)
        XCTAssertEqual(mock.addedRequests.first?.identifier, "daily_practice_reminder")
    }

    func testScheduleDailyReminder_removesExistingFirst() {
        let mock = MockNotificationCenter()
        let scheduler = makeScheduler(mock: mock)
        scheduler.scheduleDailyReminder(currentStreak: 0, onboardingComplete: true)
        XCTAssertTrue(mock.removedIdentifiers.contains("daily_practice_reminder"))
    }

    func testScheduleDailyReminder_onboardingIncomplete_doesNotAdd() {
        let mock = MockNotificationCenter()
        let scheduler = makeScheduler(mock: mock)
        scheduler.scheduleDailyReminder(currentStreak: 5, onboardingComplete: false)
        XCTAssertTrue(mock.addedRequests.isEmpty)
    }

    func testCancelAllReminders_callsRemoveAll() {
        let mock = MockNotificationCenter()
        let scheduler = makeScheduler(mock: mock)
        scheduler.cancelAllReminders()
        XCTAssertTrue(mock.removeAllCalled)
    }

    func testCancelReminder_specificIdentifier() {
        let mock = MockNotificationCenter()
        let scheduler = makeScheduler(mock: mock)
        scheduler.cancelReminder(identifier: "some_id")
        XCTAssertTrue(mock.removedIdentifiers.contains("some_id"))
    }

    func testPermissionStatus_updatesAfterRequest() {
        let mock = MockNotificationCenter()
        mock.authorizationGranted = true
        let scheduler = makeScheduler(mock: mock)
        XCTAssertEqual(scheduler.permissionStatus, .notDetermined)
        let exp = expectation(description: "perm")
        scheduler.requestPermission { _ in exp.fulfill() }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(scheduler.permissionStatus, .authorized)
    }
}

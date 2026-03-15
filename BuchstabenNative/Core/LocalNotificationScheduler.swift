import Foundation
import UserNotifications

// MARK: - Permission gate

enum NotificationPermissionStatus: Equatable {
    case notDetermined
    case authorized
    case denied
    case provisional
}

// MARK: - Quiet hours

struct QuietHours: Equatable {
    let startHour: Int   // 0–23
    let endHour: Int     // 0–23 (exclusive)

    /// Returns true if `hour` falls within quiet hours.
    func isQuiet(hour: Int) -> Bool {
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        } else {
            // Wraps midnight, e.g. 22–08
            return hour >= startHour || hour < endHour
        }
    }
}

// MARK: - Reminder content

struct ReminderContent: Equatable {
    let identifier: String
    let title: String
    let body: String
    let hour: Int
    let minute: Int
}

// MARK: - Notification center protocol (for testability)

protocol UserNotificationCenterProtocol: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void)
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeAllPendingNotificationRequests()
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol {}

// MARK: - Daily practice reminder policy

protocol DailyReminderPolicy {
    /// Produce reminder content given current streak and onboarding state.
    func content(currentStreak: Int, onboardingComplete: Bool, calendar: Calendar) -> ReminderContent?
}

struct DefaultDailyReminderPolicy: DailyReminderPolicy {
    let defaultHour: Int
    let defaultMinute: Int
    let quietHours: QuietHours

    init(defaultHour: Int = 17, defaultMinute: Int = 0,
         quietHours: QuietHours = QuietHours(startHour: 21, endHour: 8)) {
        self.defaultHour = defaultHour
        self.defaultMinute = defaultMinute
        self.quietHours = quietHours
    }

    func content(currentStreak: Int, onboardingComplete: Bool, calendar: Calendar) -> ReminderContent? {
        guard onboardingComplete else { return nil }
        guard !quietHours.isQuiet(hour: defaultHour) else { return nil }

        let body: String
        switch currentStreak {
        case 0:
            body = "Time to practice your letters today! 🔤"
        case 1:
            body = "Great start! Keep going — day 2 awaits! ⭐"
        case 2:
            body = "2 days in a row! Can you make it 3? 🌟"
        case 3...6:
            body = "You're on a \(currentStreak)-day streak — keep it going! 🔥"
        case 7...:
            body = "Incredible \(currentStreak)-day streak! You're a letter master! 🏆"
        default:
            body = "Time to practice your letters today! 🔤"
        }

        return ReminderContent(
            identifier: "daily_practice_reminder",
            title: "Buchstaben Lernen",
            body: body,
            hour: defaultHour,
            minute: defaultMinute
        )
    }
}

// MARK: - Scheduler

@MainActor
final class LocalNotificationScheduler {

    private let center: UserNotificationCenterProtocol
    private let policy: DailyReminderPolicy
    private let calendar: Calendar
    private(set) var permissionStatus: NotificationPermissionStatus = .notDetermined

    init(center: UserNotificationCenterProtocol = UNUserNotificationCenter.current(),
         policy: DailyReminderPolicy = DefaultDailyReminderPolicy(),
         calendar: Calendar = .current) {
        self.center = center
        self.policy = policy
        self.calendar = calendar
    }

    func requestPermission(completion: @escaping @Sendable (NotificationPermissionStatus) -> Void) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            let status: NotificationPermissionStatus = granted ? .authorized : .denied
            MainActor.assumeIsolated { self?.permissionStatus = status }
            completion(status)
        }
    }

    func scheduleDailyReminder(currentStreak: Int, onboardingComplete: Bool) {
        guard let content = policy.content(
            currentStreak: currentStreak,
            onboardingComplete: onboardingComplete,
            calendar: calendar
        ) else { return }

        center.removePendingNotificationRequests(withIdentifiers: [content.identifier])

        var dateComponents = DateComponents()
        dateComponents.hour = content.hour
        dateComponents.minute = content.minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let unContent = UNMutableNotificationContent()
        unContent.title = content.title
        unContent.body = content.body
        unContent.sound = .default

        let request = UNNotificationRequest(
            identifier: content.identifier,
            content: unContent,
            trigger: trigger
        )
        center.add(request, withCompletionHandler: nil)
    }

    func cancelAllReminders() {
        center.removeAllPendingNotificationRequests()
    }

    func cancelReminder(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

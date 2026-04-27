import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Schedules a daily local "time to wind down" reminder.
///
/// The product is offline-first; this is a *local* notification only.
/// No remote push, no APNs, no provisional auth needed.
public protocol BedtimeReminderServicing: Sendable {
    func requestAuthorization() async -> Bool
    func schedule(at hour: Int, minute: Int) async
    func cancel() async
}

public final class BedtimeReminderService: BedtimeReminderServicing {
    public static let identifier = "com.sleeptracker.bedtime.daily"
    private let titleKey: String
    private let bodyKey: String

    public init(titleKey: String = "notification.bedtime.title",
                bodyKey: String = "notification.bedtime.body") {
        self.titleKey = titleKey
        self.bodyKey = bodyKey
    }

    public func requestAuthorization() async -> Bool {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    public func schedule(at hour: Int, minute: Int) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString(titleKey, comment: "")
        content.body  = NSLocalizedString(bodyKey, comment: "")
        content.sound = .default

        var components = DateComponents()
        components.hour = max(0, min(23, hour))
        components.minute = max(0, min(59, minute))

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: Self.identifier,
                                            content: content,
                                            trigger: trigger)
        try? await center.add(request)
        #endif
    }

    public func cancel() async {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        #endif
    }
}

import Foundation
import UIKit
import UserNotifications

@MainActor
final class ReminderNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotifications()

    private let center = UNUserNotificationCenter.current()
    private let queueLimit = 60
    private var reconciliationTask: Task<Void, Never>?

    private override init() {
        super.init()
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: "PRODUCT_CONSUMED", title: "Consumed", options: []),
            UNNotificationAction(identifier: "PRODUCT_THROWN", title: "Thrown", options: []),
            UNNotificationAction(identifier: "PRODUCT_SNOOZE", title: "Snooze 1 day", options: [])
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "PRODUCT_EXPIRY", actions: actions, intentIdentifiers: [], options: [])
        ])
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            print("[Notifications] Permission denied; reminders are disabled")
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                print("[Notifications] Authorization granted: \(granted)")
                return granted
            } catch {
                print("[Notifications] Authorization request failed: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    func reconcile(now: Date = Date()) async {
        // Main-actor methods can interleave at awaits. Queue complete refreshes so an
        // older snapshot cannot re-add reminders removed by a newer refresh.
        let previous = reconciliationTask
        let task = Task { @MainActor in
            await previous?.value
            await self.rebuildQueue(now: now)
        }
        reconciliationTask = task
        await task.value
    }

    private func rebuildQueue(now: Date) async {
        guard ProductStore.shared.loadError == nil else { return }
        do {
            try ProductStore.shared.clearExpiredSnoozes(now: now)
        } catch {
            print("[Notifications] Could not clear expired snoozes: \(error.localizedDescription)")
        }

        center.removePendingNotificationRequests(withIdentifiers: await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("expiry.") })

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else {
            print("[Notifications] Reminder queue not scheduled; authorization is unavailable")
            return
        }

        let active = ProductStore.shared.products.filter { $0.status == .active }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let selected = Self.scheduledCandidates(for: active, now: now, calendar: calendar, queueLimit: queueLimit)

        for item in selected {
            let content = UNMutableNotificationContent()
            content.title = item.product.name
            content.body = "\(item.product.dateKind.rawValue) \(item.product.expiryDate.formatted)"
            content.categoryIdentifier = "PRODUCT_EXPIRY"
            content.sound = .default
            content.userInfo = ["productID": item.product.id.uuidString]

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger))
            } catch {
                print("[Notifications] Could not schedule \(item.identifier): \(error.localizedDescription)")
            }
        }
        print("[Notifications] Reconciled \(selected.count) pending reminder(s) for \(active.count) active product(s)")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let rawID = userInfo["productID"] as? String, let id = UUID(uuidString: rawID) else {
            completionHandler()
            return
        }

        Task { @MainActor in
            do {
                switch response.actionIdentifier {
                case "PRODUCT_CONSUMED":
                    try ProductStore.shared.markForRepurchase(id, disposition: "Consumed")
                case "PRODUCT_THROWN":
                    try ProductStore.shared.markForRepurchase(id, disposition: "Thrown")
                case "PRODUCT_SNOOZE":
                    try ProductStore.shared.setSnooze(id, until: Date().addingTimeInterval(24 * 60 * 60))
                default:
                    break
                }
            } catch {
                print("[Notifications] Could not apply notification action: \(error.localizedDescription)")
            }
            await self.reconcile()
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    // Pure calendar planning is kept separate from notification-center I/O.
    static func scheduledCandidates(
        for active: [ProductRecord],
        now: Date,
        calendar: Calendar,
        queueLimit: Int = 60
    ) -> [Candidate] {
        let today = LocalCalendarDate(date: now, calendar: calendar)
        var upcoming: [Candidate] = []
        var snoozeCandidates: [Candidate] = []
        var overdueFirst: [Candidate] = []
        var overdueSeries: [(product: ProductRecord, first: Date, interval: Calendar.Component)] = []

        for product in active {
            let snoozedUntil = product.snoozedUntil.flatMap { $0 > now ? $0 : nil }
            if let snoozedUntil {
                snoozeCandidates.append(candidate(for: product, at: snoozedUntil, suffix: "snooze"))
            }

            guard let expiryDay = product.expiryDate.date(at: 12, calendar: calendar) else {
                print("[Notifications] Could not construct Gregorian expiry date for product \(product.id.uuidString)")
                continue
            }
            let expiryStart = calendar.startOfDay(for: expiryDay)
            let todayStart = calendar.startOfDay(for: now)

            if product.expiryDate > today {
                for offset in -3...0 {
                    guard let reminderDay = calendar.date(byAdding: .day, value: offset, to: expiryStart),
                          let fireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: reminderDay),
                          fireDate > now else { continue }
                    guard snoozedUntil.map({ fireDate > $0 }) ?? true else { continue }
                    upcoming.append(candidate(for: product, at: fireDate))
                }
                // Include the post-expiry series now; the app may remain suspended
                // across the expiry day and cannot replenish its queue on its own.
                if let expiryReminder = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: expiryStart) {
                    let interval: Calendar.Component = product.dateKind == .useBy ? .hour : .day
                    overdueSeries.append((product, expiryReminder, interval))
                }
            } else if product.expiryDate == today,
                      let expiryReminder = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: expiryStart),
                      expiryReminder > now {
                if snoozedUntil.map({ expiryReminder > $0 }) ?? true {
                    upcoming.append(candidate(for: product, at: expiryReminder))
                }
                let interval: Calendar.Component = product.dateKind == .useBy ? .hour : .day
                overdueSeries.append((product, expiryReminder, interval))
            } else {
                let interval: Calendar.Component = product.dateKind == .useBy ? .hour : .day
                let first: Date
                if product.dateKind == .useBy {
                    first = calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
                } else {
                    let reminderToday = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: todayStart) ?? todayStart
                    first = reminderToday > now
                        ? reminderToday
                        : (calendar.date(byAdding: .day, value: 1, to: reminderToday) ?? now.addingTimeInterval(86400))
                }
                if snoozedUntil.map({ first > $0 }) ?? true {
                    overdueFirst.append(candidate(for: product, at: first))
                }
                overdueSeries.append((product, first, interval))
            }
        }

        snoozeCandidates.sort()
        upcoming.sort()
        overdueFirst.sort()
        var selected = Array(snoozeCandidates.prefix(queueLimit))
        if selected.count < queueLimit {
            selected.append(contentsOf: upcoming.prefix(queueLimit - selected.count))
        }
        if selected.count < queueLimit {
            selected.append(contentsOf: overdueFirst.prefix(queueLimit - selected.count))
        }
        if selected.count < queueLimit {
            // Fairly distribute the remaining requests among overdue products. iOS limits
            // pending local notifications to 64 per app; keep four slots in reserve.
            for step in 1...queueLimit {
                for series in overdueSeries {
                    guard selected.count < queueLimit,
                          let nextDate = calendar.date(byAdding: series.interval, value: step, to: series.first) else { break }
                    if series.product.snoozedUntil.map({ $0 > now && nextDate <= $0 }) == true {
                        continue
                    }
                    selected.append(candidate(for: series.product, at: nextDate))
                }
                if selected.count >= queueLimit { break }
            }
        }

        return selected
    }

    private static func candidate(for product: ProductRecord, at date: Date, suffix: String = "") -> Candidate {
        let stamp = Int(date.timeIntervalSince1970)
        let suffixPart = suffix.isEmpty ? "" : ".\(suffix)"
        return Candidate(
            product: product,
            date: date,
            identifier: "expiry.\(product.id.uuidString).\(stamp)\(suffixPart)"
        )
    }

    struct Candidate: Comparable {
        static func == (lhs: ReminderNotifications.Candidate, rhs: ReminderNotifications.Candidate) -> Bool {
            lhs.date == rhs.date && lhs.identifier == rhs.identifier
        }

        var product: ProductRecord
        var date: Date
        var identifier: String

        static func < (lhs: Candidate, rhs: Candidate) -> Bool {
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.identifier < rhs.identifier
        }
    }
}

@MainActor
final class DateExpiryAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = ReminderNotifications.shared
        return true
    }
}

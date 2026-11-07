import Foundation
import Testing
@testable import Scheduling

private enum TestError: Error { case invalidDate }

private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Sydney") ?? .gmt
    return calendar
}

private func date(_ day: Int, _ hour: Int = 9, year: Int = 2026, month: Int = 11) throws -> Date {
    guard let date = calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour)) else {
        throw TestError.invalidDate
    }
    return date
}

private func product(kind: ProductDateKind = .useBy, snoozedUntil: Date? = nil) -> ProductRecord {
    ProductRecord(id: UUID(), name: "Milk", expiryDate: LocalCalendarDate(year: 2026, month: 11, day: 8),
                  dateKind: kind, status: .active, snoozedUntil: snoozedUntil)
}

@Test @MainActor func futureUseByIncludesHourlyFollowUps() throws {
    let candidates = ReminderNotifications.scheduledCandidates(for: [product()], now: try date(7), calendar: calendar())
    #expect(candidates.count == 60)
    #expect(candidates.contains { $0.date == (try? date(8, 9)) })
    #expect(candidates.contains { $0.date == (try? date(8, 10)) })
    #expect(candidates.contains { $0.date == (try? date(8, 11)) })
}

@Test @MainActor func futureBestBeforeIncludesDailyFollowUps() throws {
    let candidates = ReminderNotifications.scheduledCandidates(for: [product(kind: .bestBefore)], now: try date(7), calendar: calendar())
    #expect(candidates.contains { $0.date == (try? date(8, 9)) })
    #expect(candidates.contains { $0.date == (try? date(9, 9)) })
    #expect(candidates.contains { $0.date == (try? date(10, 9)) })
    #expect(!candidates.contains { $0.date == (try? date(8, 10)) })
}

@Test @MainActor func snoozeSuppressesEarlierReminders() throws {
    let snooze = try date(8, 12)
    let candidates = ReminderNotifications.scheduledCandidates(for: [product(snoozedUntil: snooze)], now: try date(7), calendar: calendar())
    #expect(candidates.contains { $0.date == snooze && $0.identifier.hasSuffix(".snooze") })
    #expect(candidates.allSatisfy { $0.date >= snooze })
    #expect(candidates.contains { $0.date == (try? date(8, 13)) })
    #expect(Set(candidates.map(\.identifier)).count == candidates.count)
    #expect(candidates.count <= 60)
}

@Test @MainActor func followUpsShareSpaceAndRespectQueuePriority() throws {
    let records = [product(), product(kind: .bestBefore)]
    let candidates = ReminderNotifications.scheduledCandidates(for: records, now: try date(7), calendar: calendar())
    #expect(candidates.count == 60)
    for record in records {
        #expect(candidates.filter { $0.product.id == record.id }.count == 30)
    }
    let fullUpcomingQueue = ReminderNotifications.scheduledCandidates(for: records, now: try date(7), calendar: calendar(), queueLimit: 2)
    #expect(fullUpcomingQueue.count == 2)
    #expect(fullUpcomingQueue.allSatisfy { $0.date == (try? date(8, 9)) })
}

@Test @MainActor func bestBeforeFollowUpsKeepLocalHourAcrossDST() throws {
    var record = product(kind: .bestBefore)
    record.expiryDate = LocalCalendarDate(year: 2026, month: 10, day: 3)
    let candidates = ReminderNotifications.scheduledCandidates(for: [record], now: try date(2, year: 2026, month: 10), calendar: calendar())
    let expiry = try date(3, year: 2026, month: 10)
    let following = try date(4, year: 2026, month: 10)
    #expect(candidates.contains { $0.date == following })
    #expect(following.timeIntervalSince(expiry) == 23 * 60 * 60)
    #expect(candidates.allSatisfy { calendar().component(.hour, from: $0.date) == 9 })
}

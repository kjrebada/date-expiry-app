import Foundation
import Combine
import UIKit

enum ProductDateKind: String, Codable, CaseIterable, Identifiable {
    case useBy = "Use by"
    case bestBefore = "Best before"

    var id: String { rawValue }
}

enum ProductStatus: String, Codable {
    case active
    case toBuyAgain
}

/// Stores a calendar day rather than an instant, so time-zone changes cannot shift the label date.
struct LocalCalendarDate: Codable, Equatable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, calendar: Calendar = .current) {
        let parts = Self.gregorianCalendar(timeZone: calendar.timeZone)
            .dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 2000
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    var formatted: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Self.gregorianCalendar(timeZone: .gmt)
        formatter.timeZone = .gmt
        formatter.dateFormat = "dd MMM yyyy"
        guard let date = date(at: 12, calendar: Self.gregorianCalendar(timeZone: .gmt)) else {
            return String(format: "%02d %02d %04d", day, month, year)
        }
        return formatter.string(from: date)
    }

    private var storageValue: String {
        String(format: "%02d/%02d/%04d", month, day, year)
    }

    func date(at hour: Int = 12, calendar: Calendar = .current) -> Date? {
        let gregorianCalendar = Self.gregorianCalendar(timeZone: calendar.timeZone)
        var parts = DateComponents()
        parts.calendar = gregorianCalendar
        parts.timeZone = gregorianCalendar.timeZone
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        return gregorianCalendar.date(from: parts)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 2,
              parts[1].count == 2,
              parts[2].count == 4,
              parts.allSatisfy({ part in part.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let year = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a date in MM/DD/YYYY format.")
        }

        let calendar = Self.gregorianCalendar(timeZone: .gmt)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "The MM/DD/YYYY date is not a valid calendar day.")
        }
        self.init(year: year, month: month, day: day)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }

    static func < (lhs: LocalCalendarDate, rhs: LocalCalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

struct ProductRecord: Codable, Identifiable {
    var id: UUID
    var name: String
    var expiryDate: LocalCalendarDate
    var dateKind: ProductDateKind
    var status: ProductStatus
    var imageFilename: String?
    var lastDisposition: String?
    var snoozedUntil: Date?

    var imageURL: URL? {
        guard let imageFilename else { return nil }
        return ProductStore.imagesDirectory.appendingPathComponent(imageFilename)
    }
}

@MainActor
final class ProductStore: ObservableObject {
    static let shared = ProductStore()

    @Published private(set) var products: [ProductRecord] = []

    private let fileManager = FileManager.default
    private let recordsURL: URL
    private(set) var loadError: String?

    nonisolated static var imagesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProductImages", isDirectory: true)
    }

    private init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        recordsURL = support.appendingPathComponent("products.json")
        do {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: Self.imagesDirectory, withIntermediateDirectories: true)
            products = try JSONDecoder().decode([ProductRecord].self, from: Data(contentsOf: recordsURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            products = []
        } catch {
            products = []
            loadError = error.localizedDescription
            print("[ProductStore] Could not load saved products: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func add(name: String, date: LocalCalendarDate, kind: ProductDateKind, image: UIImage?) throws -> ProductRecord {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw StoreError.missingName
        }

        var filename: String?
        if let image {
            guard let data = image.jpegData(compressionQuality: 0.88) else {
                throw StoreError.imageEncodingFailed
            }
            let imageName = "\(UUID().uuidString).jpg"
            try data.write(to: Self.imagesDirectory.appendingPathComponent(imageName), options: .atomic)
            filename = imageName
        }

        let record = ProductRecord(
            id: UUID(),
            name: cleanName,
            expiryDate: date,
            dateKind: kind,
            status: .active,
            imageFilename: filename,
            lastDisposition: nil,
            snoozedUntil: nil
        )
        products.insert(record, at: 0)
        do {
            try persist()
        } catch {
            products.removeAll { $0.id == record.id }
            if let filename {
                try? fileManager.removeItem(at: Self.imagesDirectory.appendingPathComponent(filename))
            }
            throw error
        }
        print("[ProductStore] Saved product \(record.id.uuidString)")
        return record
    }

    func markForRepurchase(_ id: UUID, disposition: String) throws {
        guard let index = products.firstIndex(where: { $0.id == id }) else { return }
        let previous = products[index]
        products[index].status = .toBuyAgain
        products[index].lastDisposition = disposition
        products[index].snoozedUntil = nil
        do {
            try persist()
        } catch {
            products[index] = previous
            throw error
        }
    }

    func update(
        _ id: UUID,
        name: String,
        date: LocalCalendarDate,
        kind: ProductDateKind
    ) throws {
        guard let index = products.firstIndex(where: { $0.id == id }) else {
            throw StoreError.productNotFound
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw StoreError.missingName
        }

        let previous = products[index]
        products[index].name = cleanName
        products[index].expiryDate = date
        products[index].dateKind = kind
        if previous.expiryDate != date {
            products[index].snoozedUntil = nil
        }
        do {
            try persist()
        } catch {
            products[index] = previous
            throw error
        }
        print("[ProductStore] Updated product \(id.uuidString)")
    }

    func removeFromRepurchase(_ id: UUID) throws {
        guard let record = products.first(where: { $0.id == id }) else { return }
        let previousProducts = products
        products.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            products = previousProducts
            throw error
        }
        if let imageURL = record.imageURL {
            try? fileManager.removeItem(at: imageURL)
        }
    }

    func setSnooze(_ id: UUID, until date: Date?) throws {
        guard let index = products.firstIndex(where: { $0.id == id }) else { return }
        let previous = products[index].snoozedUntil
        products[index].snoozedUntil = date
        do {
            try persist()
        } catch {
            products[index].snoozedUntil = previous
            throw error
        }
    }

    func clearExpiredSnoozes(now: Date = Date()) throws {
        let previousProducts = products
        var changed = false
        for index in products.indices where products[index].snoozedUntil.map({ $0 <= now }) == true {
            products[index].snoozedUntil = nil
            changed = true
        }
        if changed {
            do {
                try persist()
            } catch {
                products = previousProducts
                throw error
            }
        }
    }

    private func persist() throws {
        // Never replace unreadable records with an empty or partial collection.
        guard loadError == nil else { throw StoreError.savedDataUnavailable }
        let data = try JSONEncoder().encode(products)
        try data.write(to: recordsURL, options: .atomic)
    }

    enum StoreError: LocalizedError {
        case missingName
        case imageEncodingFailed
        case productNotFound
        case savedDataUnavailable

        var errorDescription: String? {
            switch self {
            case .savedDataUnavailable: "Saved products could not be loaded. Changes are disabled to protect your existing data. Restart the app to try again."
            case .missingName: "Enter a product name before saving."
            case .imageEncodingFailed: "The captured image could not be saved. Please try taking the photo again."
            case .productNotFound: "This product could not be found. Please refresh and try again."
            }
        }
    }
}

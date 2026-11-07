import Foundation
import ImageIO
import UIKit
import Vision

struct OCRSuggestion {
    var productName: String?
    var date: LocalCalendarDate?
}

enum ExpiryOCR {
    static func recognize(in image: UIImage) -> OCRSuggestion {
        guard let cgImage = image.cgImage else {
            print("[ExpiryOCR] Captured image could not be decoded for text recognition")
            return OCRSuggestion(productName: nil, date: nil)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: imageOrientation(image.imageOrientation)).perform([request])
        } catch {
            print("[ExpiryOCR] Text recognition failed: \(error.localizedDescription)")
            return OCRSuggestion(productName: nil, date: nil)
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let detectedDate = lines.lazy.compactMap(parseDate).first
        let name = lines.compactMap(cleanNameCandidate).first

        return OCRSuggestion(productName: name, date: detectedDate)
    }

    private static func cleanNameCandidate(_ line: String) -> String? {
        let datePatterns = [
            #"\b\d{1,4}[/-]\d{1,2}[/-]\d{1,4}\b"#,
            #"\b(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\s+\d{1,2},?\s+\d{2,4}\b"#,
            #"\b\d{1,2}\s+(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\s+\d{4}\b"#
        ]
        var candidate = line
        for pattern in datePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(candidate.startIndex..., in: candidate)
            candidate = regex.stringByReplacingMatches(in: candidate, range: range, withTemplate: " ")
        }

        let labelPattern = #"\b(?:BEST\s+BEFORE|USE\s+BY|SELL\s+BY|EXPIRY\s+DATE|EXPIRY|EXP|MFG|LOT)\b"#
        if let regex = try? NSRegularExpression(pattern: labelPattern, options: [.caseInsensitive]) {
            let range = NSRange(candidate.startIndex..., in: candidate)
            candidate = regex.stringByReplacingMatches(in: candidate, range: range, withTemplate: " ")
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard candidate.count >= 2,
              candidate.rangeOfCharacter(from: .letters) != nil else { return nil }
        return candidate
    }

    private static func parseDate(_ text: String) -> LocalCalendarDate? {
        let patterns = [
            #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#,
            #"\b\d{4}[/-]\d{1,2}[/-]\d{1,2}\b"#,
            #"\b(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\s+\d{1,2},?\s+\d{2,4}\b"#,
            #"\b\d{1,2}\s+(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\s+\d{4}\b"#
        ]
        let formatters: [DateFormatter] = {
            let formats = [
                "d/M/yyyy", "d/MM/yyyy", "dd/M/yyyy", "dd/MM/yyyy",
                "d-M-yyyy", "d-MM-yyyy", "dd-M-yyyy", "dd-MM-yyyy",
                "d/M/yy", "d/MM/yy", "dd/M/yy", "dd/MM/yy",
                "d-M-yy", "d-MM-yy", "dd-M-yy", "dd-MM-yy",
                "yyyy-MM-dd", "yyyy/MM/dd", "MMM d yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMMM d, yyyy",
                "d MMM yyyy", "d MMMM yyyy"
            ]
            return formats.map {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = .current
                formatter.dateFormat = $0
                formatter.isLenient = false
                return formatter
            }
        }()

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let candidate = String(text[matchRange]).replacingOccurrences(of: ",", with: "")
                let numericParts = candidate.split(whereSeparator: { $0 == "/" || $0 == "-" })
                let isNumericDate = numericParts.count == 3
                    && numericParts.allSatisfy { part in part.allSatisfy { $0.isNumber } }
                let inputYearFirst = numericParts.first?.count == 4
                let inputYearLength = inputYearFirst ? numericParts.first?.count : numericParts.last?.count

                for formatter in formatters {
                    if isNumericDate {
                        let formatParts = formatter.dateFormat.split(whereSeparator: { $0 == "/" || $0 == "-" })
                        let formatYearFirst = formatParts.first?.count == 4
                        let formatYearLength = formatYearFirst ? formatParts.first?.count : formatParts.last?.count
                        guard inputYearFirst == formatYearFirst,
                              inputYearLength == formatYearLength else { continue }
                    }
                    if let date = formatter.date(from: candidate) {
                        return LocalCalendarDate(date: date)
                    }
                }
            }
        }
        return nil
    }

    private static func imageOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

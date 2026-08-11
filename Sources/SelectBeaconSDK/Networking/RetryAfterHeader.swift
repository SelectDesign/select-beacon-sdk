import Foundation

/// Parses HTTP `Retry-After` (delay-seconds or HTTP-date) into a non-negative delay.
enum RetryAfterHeader {
    /// Returns seconds to wait, or `nil` when the header is missing/unparseable.
    static func delay(
        from rawValue: String?,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        if let seconds = Int(trimmed), seconds >= 0 {
            return TimeInterval(seconds)
        }

        // RFC 9110 allows an HTTP-date (IMF-fix).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else {
            return nil
        }
        return max(0, date.timeIntervalSince(now))
    }
}

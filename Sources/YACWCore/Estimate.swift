import Foundation

/// Source D: estimated 5h window from local logs. No percentage, only start and renewal time.
/// Caveat: only counts this Mac's Claude Code usage; chat/mobile/other machines also consume the window.
public enum LocalEstimate {
    public static let windowLength: TimeInterval = 5 * 3600

    /// A window starts at the first response after the previous window ended and lasts 5h.
    /// Returns the window containing `now`, or nil if the latest window already ended.
    public static func currentFiveHourWindow(records: [UsageRecord], now: Date = Date()) -> (start: Date, end: Date)? {
        var start: Date?
        for t in records.map(\.timestamp).sorted() {
            if start == nil || t >= start!.addingTimeInterval(windowLength) { start = t }
        }
        guard let s = start, now < s.addingTimeInterval(windowLength) else { return nil }
        return (s, s.addingTimeInterval(windowLength))
    }
}

import Foundation

/// The speed-test card's formatters. Only this panel uses them.

func speedTestRateText(_ megabitsPerSecond: Double?) -> String {
    guard let megabitsPerSecond else { return "-- Mbps" }
    return String(format: megabitsPerSecond >= 100 ? "%.0f Mbps" : "%.1f Mbps", max(0, megabitsPerSecond))
}

func speedTestLatencyText(_ milliseconds: Double?) -> String {
    guard let milliseconds else { return "-- ms" }
    return String(format: milliseconds >= 10 ? "%.0f ms" : "%.1f ms", max(0, milliseconds))
}

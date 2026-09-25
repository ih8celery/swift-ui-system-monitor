import Foundation

/// A byte count as text in 1024-based units labelled B, KB, MB, GB or TB, e.g. `1.50 GB`: whole
/// bytes below a kilobyte, two decimals below 10 of a unit, one decimal above.
public func byteString(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }

    if index == 0 {
        return "\(Int(value)) \(units[index])"
    }

    return String(format: value >= 10 ? "%.1f %@" : "%.2f %@", value, units[index])
}

/// A rate in bytes per second as text in 1024-based units, B/s to GB/s, e.g. `2.5 MB/s`. A
/// negative rate reads as `0 B/s`.
public func rateString(_ bytesPerSecond: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = max(0, bytesPerSecond)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return String(format: value >= 10 || index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
}

/// A percent with one decimal place, e.g. `42.5%`. Negative values read as `0.0%`; nothing
/// caps the top, so a single-core `ps` figure of 250 reads as `250.0%`.
public func percentString(_ value: Double) -> String {
    String(format: "%.1f%%", max(0, value))
}

/// Compact "how long ago" for status lines: seconds, then minutes, then hours.
public func relativeTimeString(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h"
}

/// A status line for when a tab's data last arrived: "Updated 12s ago", or "Waiting for
/// sample" before the first. Always in whole seconds, unlike `relativeTimeString(_:now:)`.
public func updatedAgoText(lastUpdated: Date?, now: Date) -> String {
    guard let lastUpdated else { return "Waiting for sample" }
    return "Updated \(max(0, Int(now.timeIntervalSince(lastUpdated))))s ago"
}

/// Whole-machine CPU percent for a process group's summed `ps` pcpu, using the
/// live active core count. One place so every process list shares the scale.
public func machineCPUPercent(_ summedPcpu: Double) -> Double {
    ProcessCPUScale.wholeMachinePercent(
        summedPcpu: summedPcpu,
        coreCount: ProcessInfo.processInfo.activeProcessorCount
    )
}

/// The four coarse levels macOS reports, as words. No number exists without root.
public func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "Nominal"
    case .fair: return "Fair"
    case .serious: return "Serious"
    case .critical: return "Critical"
    @unknown default: return "Unknown"
    }
}

import Foundation

/// A byte count as text in 1024-based units labelled B, KB, MB, GB or TB, e.g. `1.50 GB`: whole
/// bytes below a kilobyte, two decimals below 10 of a unit, one decimal above.
public func byteString(_ bytes: UInt64) -> String {
    let (value, index) = scaled(Double(bytes), base: 1024, unitCount: byteUnits.count)
    if index == 0 {
        return "\(Int(value)) \(byteUnits[index])"
    }

    return String(format: value >= 10 ? "%.1f %@" : "%.2f %@", value, byteUnits[index])
}

/// A file, disk or download size as text in 1000-based units, as Finder and Disk Utility count
/// them, labelled B, KB, MB, GB or TB: whole bytes below a kilobyte, one decimal above, e.g.
/// 1 500 000 000 bytes reads `1.5 GB`. Use `memoryByteString(_:)` for RAM.
public func fileByteString(_ bytes: UInt64) -> String {
    oneDecimalByteString(bytes, base: 1000)
}

/// An amount of memory as text in 1024-based units, as Activity Monitor counts it, labelled B,
/// KB, MB, GB or TB: whole bytes below a kilobyte, one decimal above, e.g. 1 500 000 000 bytes
/// reads `1.4 GB` and 16 GiB of RAM reads `16.0 GB`. Use `fileByteString(_:)` for files.
public func memoryByteString(_ bytes: UInt64) -> String {
    oneDecimalByteString(bytes, base: 1024)
}

/// A rate in bytes per second as text in 1024-based units, B/s to GB/s, e.g. `2.5 MB/s`. A
/// negative rate reads as `0 B/s`.
public func rateString(_ bytesPerSecond: Double) -> String {
    rateText(bytesPerSecond, base: 1024)
}

/// A disk or network speed in bytes per second as text in 1000-based units, as Finder and
/// Disk Utility count them, B/s to GB/s: whole numbers from 10 of a unit, e.g. `12 KB/s`, one
/// decimal below, e.g. 2 500 000 reads `2.5 MB/s`. A negative rate reads as `0 B/s`.
public func fileRateString(_ bytesPerSecond: Double) -> String {
    rateText(bytesPerSecond, base: 1000)
}

private let byteUnits = ["B", "KB", "MB", "GB", "TB"]
private let rateUnits = ["B/s", "KB/s", "MB/s", "GB/s"]

/// Divides by `base` until the value is below it or the units run out; returns the value and
/// the index of its unit.
private func scaled(_ value: Double, base: Double, unitCount: Int) -> (Double, Int) {
    var value = value
    var index = 0
    while value >= base, index < unitCount - 1 {
        value /= base
        index += 1
    }
    return (value, index)
}

private func oneDecimalByteString(_ bytes: UInt64, base: Double) -> String {
    let (value, index) = scaled(Double(bytes), base: base, unitCount: byteUnits.count)
    if index == 0 {
        return "\(Int(value)) \(byteUnits[index])"
    }

    return String(format: "%.1f %@", value, byteUnits[index])
}

private func rateText(_ bytesPerSecond: Double, base: Double) -> String {
    let (value, index) = scaled(max(0, bytesPerSecond), base: base, unitCount: rateUnits.count)
    return String(format: value >= 10 || index == 0 ? "%.0f %@" : "%.1f %@", value, rateUnits[index])
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

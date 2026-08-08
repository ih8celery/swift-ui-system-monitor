import AppKit
import Foundation
import SwiftUI

func byteString(_ bytes: UInt64) -> String {
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

func rateString(_ bytesPerSecond: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = max(0, bytesPerSecond)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return String(format: value >= 10 || index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
}

func speedTestRateText(_ megabitsPerSecond: Double?) -> String {
    guard let megabitsPerSecond else { return "-- Mbps" }
    return String(format: megabitsPerSecond >= 100 ? "%.0f Mbps" : "%.1f Mbps", max(0, megabitsPerSecond))
}

func speedTestLatencyText(_ milliseconds: Double?) -> String {
    guard let milliseconds else { return "-- ms" }
    return String(format: milliseconds >= 10 ? "%.0f ms" : "%.1f ms", max(0, milliseconds))
}

func percentString(_ value: Double) -> String {
    String(format: "%.1f%%", max(0, value))
}

func batteryStatLabel(percent: Int, isCharging: Bool?) -> String {
    isCharging == true ? "\(percent)% Charging" : "\(percent)%"
}

func swapStatText(used: UInt64, total: UInt64) -> String {
    "\(byteString(used)) / \(byteString(total))"
}

func updatedAgoText(lastUpdated: Date?, now: Date) -> String {
    guard let lastUpdated else { return "Waiting for sample" }
    return "Updated \(max(0, Int(now.timeIntervalSince(lastUpdated))))s ago"
}

/// Whole-machine CPU percent for a process group's summed `ps` pcpu, using the
/// live active core count. One place so every process list shares the scale.
func machineCPUPercent(_ summedPcpu: Double) -> Double {
    ProcessCPUScale.wholeMachinePercent(
        summedPcpu: summedPcpu,
        coreCount: ProcessInfo.processInfo.activeProcessorCount
    )
}


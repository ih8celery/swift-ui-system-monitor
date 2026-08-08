import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    func collectPower() {
        guard !isCollectingPower else { return }
        isCollectingPower = true
        defer { isCollectingPower = false }

        var snapshot = Self.collectPowerSnapshot()
        let sampleDate = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            snapshot.contributors = Self.powerContributors(from: self.processSummary.topCPU)
            snapshot.lastUpdated = sampleDate
            self.powerSnapshot = snapshot
        }
    }


    static func collectPowerSnapshot() -> PowerSnapshot {
        let battery = runProcess(path: "/usr/bin/pmset", arguments: ["-g", "batt"])
        let assertions = runProcess(path: "/usr/bin/pmset", arguments: ["-g", "assertions"])
        let parsedBattery = parseBatteryStatus(battery.output)
        let parsedAssertions = assertions.status == 0 ? parseSleepAssertions(assertions.output) : []
        var status: [String] = []
        if battery.status != 0 { status.append("battery unavailable") }
        if assertions.status != 0 { status.append("assertions unavailable") }

        return PowerSnapshot(
            powerSource: parsedBattery.powerSource,
            thermalState: thermalStateLabel(ProcessInfo.processInfo.thermalState),
            batteryPercent: parsedBattery.percent,
            isCharging: parsedBattery.isCharging,
            sleepAssertions: parsedAssertions,
            contributors: [],
            status: status.isEmpty ? "Power sample OK" : status.joined(separator: ", "),
            health: SampleHealth(isOK: status.isEmpty),
            lastUpdated: Date()
        )
    }

    static func powerContributors(from rows: [ProcessSnapshot]) -> [PowerContributor] {
        rows.prefix(5).map { row in
            PowerContributor(
                name: row.name,
                evidence: "\(percentString(row.cpu)) CPU, \(byteString(row.physical)) memory"
            )
        }
    }

    static func parseBatteryStatus(_ output: String) -> (powerSource: String, state: String, percent: Int?, isCharging: Bool?) {
        var powerSource = "Unknown power"
        var state = "Battery unavailable"
        var percent: Int?
        var isCharging: Bool?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Now drawing from") {
                powerSource = line
                    .replacingOccurrences(of: "Now drawing from", with: "")
                    .replacingOccurrences(of: "'", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.contains("%;") {
                let parts = line.components(separatedBy: ";").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let percentPart = parts.first,
                   let percentToken = percentPart.split(whereSeparator: \.isWhitespace).last {
                    percent = Int(percentToken.replacingOccurrences(of: "%", with: ""))
                }
                if parts.count > 1 {
                    state = parts[1]
                    let lower = state.lowercased()
                    isCharging = lower.contains("charging") || lower.contains("charged")
                }
            }
        }

        return (powerSource, state, percent, isCharging)
    }

    static func parseSleepAssertions(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("prevent") && !lower.contains("= 0")
            }
            .prefix(8)
            .map { String($0) }
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    // Every displayed row groups by process name; only the groups that land in
    // that display need a per-PID proc_pid_rusage syscall, so both the
    // snapshot pass and ProcessSummary's slice share these limits.
    static let processMemoryDisplayLimit = 18
    static let processCPUDisplayLimit = 28


}

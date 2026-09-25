import Foundation
import SystemBarKit

/// Two pmset reads and the parsing of them. Pure apart from `collect(using:)`.
enum PowerCollector {
    static func collect(using host: HostServices) -> PowerSnapshot {
        let battery = host.run(path: "/usr/bin/pmset", arguments: ["-g", "batt"])
        let assertions = host.run(path: "/usr/bin/pmset", arguments: ["-g", "assertions"])
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

    static func contributors(from rows: [ProcessSnapshot]) -> [PowerContributor] {
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
}

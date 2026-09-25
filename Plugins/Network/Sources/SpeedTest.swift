import Foundation
import SystemBarKit

/// Apple's networkQuality, run only when the button is pressed, and what its output means.
enum SpeedTest {
    /// -M 20 caps the test itself at about 20 seconds; this leaves room to start up and report.
    static let timeout: TimeInterval = 30

    /// Blocks for up to `timeout`, so the plugin calls it on its speed-test queue.
    static func measure(using host: HostServices, startedAt: Date) -> SpeedTestOutcome {
        let output = host.run(path: "/usr/bin/networkQuality", arguments: ["-c", "-M", "20"], timeout: timeout)
        let finishedAt = Date()
        let parsed = output.status == 0 ? parseNetworkQualityOutput(
            output.output,
            measuredAt: finishedAt,
            duration: finishedAt.timeIntervalSince(startedAt)
        ) : nil
        return SpeedTestOutcome(result: parsed, failure: speedTestFailureMessage(output))
    }

    private static func parseNetworkQualityOutput(_ output: String, measuredAt: Date, duration: TimeInterval) -> SpeedTestResult? {
        if let result = parseNetworkQualityJSON(output, measuredAt: measuredAt, duration: duration) {
            return result
        }

        return parseNetworkQualitySummary(output, measuredAt: measuredAt, duration: duration)
    }

    static func parseNetworkQualityJSON(_ output: String, measuredAt: Date, duration: TimeInterval) -> SpeedTestResult? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let downloadMbps = doubleValue(dictionary["dl_throughput"]).map { $0 / 1_000_000 }
        let uploadMbps = doubleValue(dictionary["ul_throughput"]).map { $0 / 1_000_000 }
        let latencyMS = doubleValue(dictionary["base_rtt"])
        let interfaceName = stringValue(dictionary["interface_name"]) ?? "Unknown interface"
        let endpoint = stringValue(dictionary["test_endpoint"]) ?? "Default endpoint"

        guard downloadMbps != nil || uploadMbps != nil || latencyMS != nil else { return nil }
        return SpeedTestResult(
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps,
            latencyMS: latencyMS,
            interfaceName: interfaceName,
            endpoint: endpoint,
            measuredAt: measuredAt,
            duration: duration
        )
    }

    static func parseNetworkQualitySummary(_ output: String, measuredAt: Date, duration: TimeInterval) -> SpeedTestResult? {
        var downloadMbps: Double?
        var uploadMbps: Double?
        var latencyMS: Double?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let lower = line.lowercased()
            if lower.contains("download capacity") || lower.contains("downlink capacity") {
                downloadMbps = megabitsPerSecond(from: line)
            } else if lower.contains("upload capacity") || lower.contains("uplink capacity") {
                uploadMbps = megabitsPerSecond(from: line)
            } else if lower.contains("idle latency") || lower.contains("base rtt") {
                latencyMS = firstNumber(in: line)
            }
        }

        guard downloadMbps != nil || uploadMbps != nil || latencyMS != nil else { return nil }
        return SpeedTestResult(
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps,
            latencyMS: latencyMS,
            interfaceName: "Default interface",
            endpoint: "Default endpoint",
            measuredAt: measuredAt,
            duration: duration
        )
    }

    private static func speedTestFailureMessage(_ output: CommandOutput) -> String {
        guard output.status != 0 else { return "Speed test output unreadable" }
        let message = [output.error, output.output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "networkQuality exited \(output.status)"
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return "Failed: \(firstLine)"
    }

    private static func megabitsPerSecond(from line: String) -> Double? {
        guard let value = firstNumber(in: line) else { return nil }
        let lower = line.lowercased()
        if lower.contains("gbps") { return value * 1_000 }
        if lower.contains("kbps") { return value / 1_000 }
        if lower.contains("bps"), !lower.contains("mbps") { return value / 1_000_000 }
        return value
    }

    private static func firstNumber(in text: String) -> Double? {
        let allowed = CharacterSet(charactersIn: "0123456789.")
        for token in text.components(separatedBy: allowed.inverted) where !token.isEmpty {
            if let value = Double(token) {
                return value
            }
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    static func shortTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

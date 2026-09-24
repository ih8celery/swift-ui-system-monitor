import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    func runSpeedTest() {
        guard !isSpeedTestRunning else { return }

        let startedAt = Date()
        isSpeedTestRunning = true
        speedTestStatus = "Testing"
        speedTestHealth = .ok

        speedTestQueue.async { [weak self] in
            // -M 20 caps the test itself at ~20s; give it room to also start up and report.
            let output = Self.runProcess(path: "/usr/bin/networkQuality", arguments: ["-c", "-M", "20"], timeout: 30)
            let finishedAt = Date()
            let parsed = output.status == 0 ? Self.parseNetworkQualityOutput(
                output.output,
                measuredAt: finishedAt,
                duration: finishedAt.timeIntervalSince(startedAt)
            ) : nil
            let failure = Self.speedTestFailureMessage(output)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isSpeedTestRunning = false
                if let parsed {
                    self.speedTestResult = parsed
                    self.speedTestStatus = "Last run \(Self.shortTimeString(parsed.measuredAt))"
                    self.speedTestHealth = .ok
                } else {
                    self.speedTestStatus = failure
                    self.speedTestHealth = .degraded
                }
            }
        }
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

    static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func shortTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func stringValue(in text: String, key: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") ?? text.range(of: key),
              let equalsRange = text[keyRange.upperBound...].range(of: "=") else {
            return nil
        }

        let suffix = text[equalsRange.upperBound...].drop(while: { $0 == " " })
        if suffix.first == "\"" {
            let afterOpeningQuote = suffix.index(after: suffix.startIndex)
            guard let closingQuote = suffix[afterOpeningQuote...].firstIndex(of: "\"") else {
                return nil
            }
            return String(suffix[afterOpeningQuote..<closingQuote])
        }

        let token = suffix.prefix { !$0.isNewline && $0 != "," && $0 != "}" }
        return String(token).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func doubleValue(in text: String, key: String) -> Double? {
        guard let value = stringValue(in: text, key: key) else { return nil }
        return Double(value.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    static func uint64Value(in text: String, key: String) -> UInt64? {
        guard let value = stringValue(in: text, key: key) else { return nil }
        return UInt64(value.filter { $0.isNumber })
    }


}

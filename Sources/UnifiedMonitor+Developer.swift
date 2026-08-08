import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    func collectDeveloper() {
        guard !isCollectingDeveloper else { return }
        isCollectingDeveloper = true
        defer { isCollectingDeveloper = false }

        let lsof = Self.runProcess(path: "/usr/sbin/lsof", arguments: ["-n", "-P", "-iTCP", "-sTCP:LISTEN"])
        let ports = lsof.status == 0 ? Self.parseListeningPorts(lsof.output) : []
        let status = lsof.status == 0 ? "Developer sample OK" : "lsof listen unavailable"
        let health = SampleHealth(isOK: lsof.status == 0)
        let sampleDate = Date()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.developerSnapshot = Self.buildDeveloperSnapshot(
                ports: ports,
                processSummary: self.processSummary,
                networkSummary: self.networkSummary,
                status: status,
                health: health,
                now: sampleDate
            )
        }
    }


    static func buildDeveloperSnapshot(
        ports: [DeveloperPort],
        processSummary: ProcessSummary,
        networkSummary: NetworkSummary,
        status: String,
        health: SampleHealth,
        now: Date
    ) -> DeveloperSnapshot {
        let networkRates = Dictionary(uniqueKeysWithValues: networkSummary.processes.map { ($0.name.lowercased(), $0.combinedRate) })
        let processRows = processSummary.topCPU + processSummary.topMemory
        var grouped: [String: ProcessSnapshot] = [:]
        for row in processRows where isDeveloperProcess(row.name) {
            let key = row.name.lowercased()
            if let current = grouped[key], row.cpu <= current.cpu, row.physical <= current.physical {
                continue
            }
            grouped[key] = row
        }

        let developerProcesses = grouped.values
            .sorted { $0.cpu == $1.cpu ? $0.physical > $1.physical : $0.cpu > $1.cpu }
            .prefix(14)
            .map { row in
                DeveloperProcess(
                    name: row.name,
                    kind: developerProcessKind(row.name),
                    count: row.count,
                    cpu: row.cpu,
                    memory: row.physical,
                    networkRate: networkRates[row.name.lowercased()] ?? 0
                )
            }

        return DeveloperSnapshot(
            ports: Array(ports.prefix(24)),
            processes: developerProcesses,
            optionalServices: optionalDeveloperServices(),
            status: status,
            health: health,
            lastUpdated: now
        )
    }

    static func parseListeningPorts(_ output: String) -> [DeveloperPort] {
        var ports: [DeveloperPort] = []
        var seen = Set<String>()

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard !line.hasPrefix("COMMAND"),
                  let tcpRange = line.range(of: " TCP "),
                  line.contains("(LISTEN)") else { continue }

            let fields = line[..<tcpRange.lowerBound].split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  let pid = Int(fields[1]) else { continue }

            let descriptor = line[tcpRange.upperBound...]
                .replacingOccurrences(of: "(LISTEN)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = port(from: descriptor) else { continue }
            let process = String(fields[0]).replacingOccurrences(of: "\\x20", with: " ")
            let key = "\(process)|\(pid)|\(port)|\(descriptor)"
            guard seen.insert(key).inserted else { continue }

            ports.append(DeveloperPort(
                process: process,
                pid: pid,
                port: port,
                localAddress: descriptor
            ))
        }

        return ports.sorted {
            if $0.port == $1.port {
                return $0.process.localizedCaseInsensitiveCompare($1.process) == .orderedAscending
            }
            return (Int($0.port) ?? Int.max) < (Int($1.port) ?? Int.max)
        }
    }

    private static func isDeveloperProcess(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["node", "python", "ruby", "swift", "xcode", "xcodebuild", "docker", "orb", "postgres", "redis", "nginx", "java", "cargo", "go", "deno", "bun", "vite"].contains { lower.contains($0) }
    }

    private static func developerProcessKind(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("node") || lower.contains("deno") || lower.contains("bun") || lower.contains("vite") { return "JS server" }
        if lower.contains("python") { return "Python" }
        if lower.contains("ruby") { return "Ruby" }
        if lower.contains("swift") || lower.contains("xcode") { return "Swift/Xcode" }
        if lower.contains("docker") || lower.contains("orb") { return "Container runtime" }
        if lower.contains("postgres") || lower.contains("redis") { return "Local data service" }
        return "Developer tool"
    }

    private static func optionalDeveloperServices() -> [String] {
        let paths = [
            "/Applications/OrbStack.app": "OrbStack installed",
            "/Applications/Docker.app": "Docker Desktop installed",
            "/opt/homebrew/bin/brew": "Homebrew available"
        ]
        return paths.compactMap { path, label in
            FileManager.default.fileExists(atPath: path) ? label : nil
        }
    }

    static func relativeTimeString(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }


}

import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    func collectNetwork() {
        guard !isCollectingNetwork else { return }
        isCollectingNetwork = true
        defer { isCollectingNetwork = false }

        let nettop = Self.runProcess(path: "/usr/bin/nettop", arguments: [
            "-d", "-P", "-L", "2", "-s", "1", "-x", "-n", "-J", "bytes_in,bytes_out"
        ])
        let lsof = Self.runProcess(path: "/usr/sbin/lsof", arguments: ["-n", "-P", "-iTCP"])
        let rows = Self.parseNettopCSV(nettop.output)
            .filter { $0.downloadRate > 0 || $0.uploadRate > 0 }
            .sorted {
                if $0.combinedRate == $1.combinedRate {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.combinedRate > $1.combinedRate
            }
        let connections = lsof.status == 0 ? Self.parseLsofTCP(lsof.output) : []
        let internet = connections.filter(\.isInternet)
        let destinations = Self.summarizeDestinations(internet)
        let status = Self.networkStatus(nettop: nettop, lsof: lsof)
        let health = SampleHealth(isOK: nettop.status == 0 && lsof.status == 0)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.networkSummary = NetworkSummary(
                processes: rows,
                destinations: destinations,
                resolvedHostnames: self.networkSummary.resolvedHostnames,
                status: status,
                health: health
            )
            self.resolveHostnames(for: destinations)
        }
    }


    private func resolveHostnames(for destinations: [NetworkDestination]) {
        let now = Date()
        for address in Set(destinations.map(\.remoteAddress)) {
            let normalized = Self.normalizedIPAddress(address)
            if let entry = hostnameCache[normalized], Self.isHostnameCacheEntryValid(entry, now: now, ttl: Self.negativeHostnameCacheTTL) {
                setResolvedHostname(entry.hostname, for: normalized)
                continue
            }

            guard !hostnameLookupsInFlight.contains(normalized) else { continue }
            hostnameLookupsInFlight.insert(normalized)

            dnsQueue.async { [weak self] in
                let hostname = Self.reverseLookup(ipAddress: normalized)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hostnameLookupsInFlight.remove(normalized)
                    self.hostnameCache[normalized] = HostnameCacheEntry(hostname: hostname, cachedAt: Date())
                    self.setResolvedHostname(hostname, for: normalized)
                }
            }
        }
    }

    /// Failed lookups (empty hostname) are a negative cache: DNS or network
    /// conditions can change, so a transient miss shouldn't pin a destination
    /// to its raw IP forever. Successful lookups don't expire — hostnames
    /// rarely change and re-querying them buys nothing.
    static let negativeHostnameCacheTTL: TimeInterval = 60

    static func isHostnameCacheEntryValid(_ entry: HostnameCacheEntry, now: Date, ttl: TimeInterval) -> Bool {
        guard entry.hostname.isEmpty else { return true }
        return now.timeIntervalSince(entry.cachedAt) < ttl
    }

    private func setResolvedHostname(_ hostname: String, for address: String) {
        var snapshot = networkSummary
        snapshot.resolvedHostnames[address] = hostname
        networkSummary = snapshot
    }


    static func parseNettopCSV(_ csv: String) -> [NetworkProcessSnapshot] {
        var totals: [String: (downloaded: UInt64, uploaded: UInt64)] = [:]
        var rates: [String: (download: Double, upload: Double)] = [:]
        var blockIndex = -1

        for rawLine in csv.split(whereSeparator: \.isNewline) {
            let fields = parseCSVLine(String(rawLine))
            guard fields.count >= 3 else { continue }

            if fields.contains("bytes_in") {
                blockIndex += 1
                continue
            }

            guard blockIndex >= 0 else { continue }
            let name = normalizedProcessName(fields[0])
            guard !name.isEmpty else { continue }
            let bytesIn = UInt64(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let bytesOut = UInt64(fields[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

            if blockIndex == 0 {
                let current = totals[name] ?? (0, 0)
                totals[name] = (current.downloaded + bytesIn, current.uploaded + bytesOut)
            } else {
                let current = rates[name] ?? (0, 0)
                rates[name] = (current.download + Double(bytesIn), current.upload + Double(bytesOut))
            }
        }

        return Set(totals.keys).union(rates.keys).map { name in
            let total = totals[name] ?? (0, 0)
            let rate = rates[name] ?? (0, 0)
            return NetworkProcessSnapshot(
                id: name,
                name: name,
                downloadRate: rate.download,
                uploadRate: rate.upload,
                totalDownloaded: total.downloaded,
                totalUploaded: total.uploaded
            )
        }
    }

    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isInQuotes = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if isInQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append(next)
                    } else {
                        isInQuotes = false
                        if next == "," {
                            fields.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    isInQuotes.toggle()
                }
            } else if character == "," && !isInQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        fields.append(current)
        return fields
    }

    private static func normalizedProcessName(_ nameWithPID: String) -> String {
        let trimmed = nameWithPID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dotIndex = trimmed.lastIndex(of: ".") else { return trimmed }
        let suffix = trimmed[trimmed.index(after: dotIndex)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return trimmed }
        return String(trimmed[..<dotIndex])
    }

    static func parseLsofTCP(_ output: String) -> [TCPConnection] {
        let trackedStates = Set(["ESTABLISHED", "SYN_SENT", "CLOSE_WAIT"])
        var connections: [TCPConnection] = []
        var seen = Set<String>()

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard !line.hasPrefix("COMMAND") else { continue }
            guard let tcpRange = line.range(of: " TCP ") else { continue }
            guard let stateStart = line.lastIndex(of: "("), line.hasSuffix(")") else { continue }

            let state = String(line[line.index(after: stateStart)..<line.index(before: line.endIndex)])
            guard trackedStates.contains(state) else { continue }
            let fields = line[..<tcpRange.lowerBound].split(whereSeparator: \.isWhitespace)
            guard let command = fields.first else { continue }

            let descriptor = line[tcpRange.upperBound..<stateStart].trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoints = descriptor.components(separatedBy: "->")
            guard endpoints.count == 2 else { continue }
            let local = endpoints[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = endpoints[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let address = address(fromEndpoint: remote) else { continue }

            let connection = TCPConnection(
                process: String(command).replacingOccurrences(of: "\\x20", with: " "),
                localEndpoint: local,
                remoteEndpoint: remote,
                remoteAddress: address,
                isInternet: !isLANAddress(address)
            )
            guard seen.insert(connection.dedupeKey).inserted else { continue }
            connections.append(connection)
        }

        return connections
    }

    private static func summarizeDestinations(_ connections: [TCPConnection]) -> [NetworkDestination] {
        var groups: [String: (process: String, endpoint: String, remoteAddress: String, count: Int)] = [:]
        for connection in connections {
            let key = "\(connection.process)|\(connection.remoteEndpoint)"
            let current = groups[key] ?? (connection.process, connection.remoteEndpoint, connection.remoteAddress, 0)
            groups[key] = (current.process, current.endpoint, current.remoteAddress, current.count + 1)
        }

        return groups.values.map {
            NetworkDestination(process: $0.process, endpoint: $0.endpoint, remoteAddress: $0.remoteAddress, count: $0.count)
        }
        .sorted {
            if $0.count == $1.count {
                return $0.endpoint.localizedCaseInsensitiveCompare($1.endpoint) == .orderedAscending
            }
            return $0.count > $1.count
        }
    }

    private static func address(fromEndpoint endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
        }
        guard let separator = trimmed.lastIndex(of: ":") else { return nil }
        return String(trimmed[..<separator])
    }

    static func port(from endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: ":") else { return nil }
        let port = trimmed[trimmed.index(after: separator)...]
        return port.isEmpty ? nil : String(port)
    }

    static func serviceLabel(endpoint: String) -> String {
        guard let port = port(from: endpoint) else {
            return "remote service"
        }

        switch port {
        case "443": return "HTTPS"
        case "80": return "HTTP"
        case "993": return "IMAPS"
        case "587": return "SMTP submit"
        case "5223": return "Apple push"
        case "22": return "SSH"
        case "3000", "3001", "5173", "8000", "8080": return "dev server"
        case "5432": return "Postgres"
        case "6379": return "Redis"
        default: return "port \(port)"
        }
    }

    static func isLANAddress(_ address: String) -> Bool {
        let stripped = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? address
        let octets = stripped.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            return octets[0] == 10
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || octets[0] == 127
        }

        let lower = stripped.lowercased()
        if lower == "::1" { return true }
        guard let first = lower.split(separator: ":", maxSplits: 1).first,
              let hextet = Int(first, radix: 16) else {
            return false
        }
        return (0xfe80...0xfebf).contains(hextet) || (0xfc00...0xfdff).contains(hextet)
    }

    private static func normalizedIPAddress(_ ipAddress: String) -> String {
        ipAddress
            .split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ipAddress
    }

    private static func reverseLookup(ipAddress: String) -> String {
        if ipAddress.contains(":") {
            return reverseLookupIPv6(ipAddress)
        }

        return reverseLookupIPv4(ipAddress)
    }

    private static func reverseLookupIPv4(_ ipAddress: String) -> String {
        var internetAddress = in_addr()
        guard inet_pton(AF_INET, ipAddress, &internetAddress) == 1 else { return "" }

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr = internetAddress

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                getnameinfo(
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NAMEREQD
                )
            }
        }

        guard result == 0 else { return "" }
        return String(cString: host)
    }

    private static func reverseLookupIPv6(_ ipAddress: String) -> String {
        var internetAddress = in6_addr()
        guard inet_pton(AF_INET6, ipAddress, &internetAddress) == 1 else { return "" }

        var socketAddress = sockaddr_in6()
        socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        socketAddress.sin6_family = sa_family_t(AF_INET6)
        socketAddress.sin6_addr = internetAddress

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                getnameinfo(
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_in6>.size),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NAMEREQD
                )
            }
        }

        guard result == 0 else { return "" }
        return String(cString: host)
    }

    private static func networkStatus(nettop: CommandOutput, lsof: CommandOutput) -> String {
        var parts: [String] = []
        if nettop.status != 0 {
            parts.append("nettop unavailable")
        }
        if lsof.status != 0 {
            parts.append("lsof unavailable")
        }
        return parts.isEmpty ? "Network sample OK" : parts.joined(separator: ", ")
    }


}

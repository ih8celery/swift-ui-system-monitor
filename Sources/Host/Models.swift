import AppKit
import Darwin
import Foundation
import SwiftUI
import SystemBarKit

enum MonitorMode: String, CaseIterable, Identifiable {
    case network = "Network"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .network: return "arrow.up.arrow.down"
        }
    }
}

struct NetworkProcessSnapshot: Identifiable {
    let id: String
    let name: String
    let downloadRate: Double
    let uploadRate: Double
    let totalDownloaded: UInt64
    let totalUploaded: UInt64

    var combinedRate: Double { downloadRate + uploadRate }
}

struct NetworkDestination: Identifiable {
    var id: String { "\(process)|\(endpoint)" }
    let process: String
    let endpoint: String
    let remoteAddress: String
    let count: Int
}

struct HostnameCacheEntry {
    let hostname: String
    let cachedAt: Date
}

enum MonitorJob: Hashable {
    case network
}

struct MonitorSamplingPlan {
    static let networkRefreshInterval: TimeInterval = 30

    static func jobs(isVisible: Bool, mode: MonitorMode) -> Set<MonitorJob> {
        guard isVisible else { return [] }

        switch mode {
        case .network:
            return [.network]
        }
    }
}

struct NetworkSummary {
    var processes: [NetworkProcessSnapshot] = []
    var totalProcessCount = 0
    var maxCombinedRate: Double = 1
    var destinations: [NetworkDestination] = []
    var resolvedHostnames: [String: String] = [:]
    var status = "Waiting for network sample"
    var health = SampleHealth.degraded

    init() {}

    init(
        processes: [NetworkProcessSnapshot],
        destinations: [NetworkDestination],
        resolvedHostnames: [String: String],
        status: String,
        health: SampleHealth,
        limit: Int = 28
    ) {
        self.totalProcessCount = processes.count
        self.maxCombinedRate = max(processes.map(\.combinedRate).max() ?? 1, 1)
        self.processes = Array(processes.prefix(limit))
        self.destinations = destinations
        self.resolvedHostnames = resolvedHostnames
        self.status = status
        self.health = health
    }
}

struct SpeedTestResult {
    let downloadMbps: Double?
    let uploadMbps: Double?
    let latencyMS: Double?
    let interfaceName: String
    let endpoint: String
    let measuredAt: Date
    let duration: TimeInterval
}

struct TCPConnection {
    let process: String
    let localEndpoint: String
    let remoteEndpoint: String
    let remoteAddress: String
    let isInternet: Bool

    var dedupeKey: String {
        "\(process)|\(localEndpoint)|\(remoteEndpoint)"
    }
}


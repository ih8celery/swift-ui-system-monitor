import AppKit
import Darwin
import Foundation
import SwiftUI
import SystemBarKit

enum MonitorMode: String, CaseIterable, Identifiable {
    case memory = "Memory"
    case network = "Network"
    case cpu = "CPU"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .cpu: return "cpu"
        }
    }
}

struct MemorySnapshot {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var available: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var purgeable: UInt64 = 0
    var free: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
}

/// Per-PID facts shown in the drill-in panel for a tapped process group.
struct ProcessDetail: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let command: String        // full args
    let path: String           // executable path
    let name: String
    let parentName: String
    let grandparentName: String
    let cpuPercent: Double     // whole-machine 0-100
    let memory: UInt64
    let uptime: String
}

/// Best-guess, plain-english identity for a process group. Prefixed "Likely:" in
/// the UI so a wrong guess reads as a guess. Rules are first-match-wins over the
/// group's exe paths, args, and 2-hop parent chain; the fallback never asserts
/// anything false — it just restates the raw parent and path.
enum ProcessClassifier {
    static func likelyLabel(for rows: [ProcessDetail]) -> String {
        guard let first = rows.first else { return "No live processes" }

        let paths = rows.map { $0.path.lowercased() }
        let args = rows.map { $0.command.lowercased() }
        // 2-hop parent chain names across every PID in the group.
        let ancestors = rows.flatMap { [$0.parentName, $0.grandparentName] }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }

        func anyPath(_ needle: String) -> Bool { paths.contains { $0.contains(needle) } }
        func anyArg(_ needle: String) -> Bool { args.contains { $0.contains(needle) } }
        func anyAncestor(_ needles: [String]) -> Bool {
            ancestors.contains { name in needles.contains { name.contains($0) } }
        }

        // 1. Xcode build.
        if anyPath("xcode.app") || anyPath(".xctoolchain") || anyPath("/developer/toolchains")
            || anyAncestor(["xcode", "xcodebuild"]) {
            let count = rows.count
            return "Xcode compiling (\(count) job\(count == 1 ? "" : "s"))"
        }

        // 2. MCP server (args mention mcp, parent is Claude or node).
        if anyArg("mcp"), let host = ancestorMatching(rows, ["claude", "node"]) {
            return "MCP server started by \(host)"
        }

        // 3. Browser jobs (browser parent + renderer/gpu/utility worker).
        if let browser = browserAncestor(rows),
           anyArg("--type=renderer") || anyArg("--type=gpu") || anyArg("--type=utility") {
            return "\(browser) page/tab work"
        }

        // 4. Node / JS tooling.
        if anyAncestor(["node", "npm", "pnpm", "yarn", "vite", "esbuild", "deno", "bun"]) {
            return "Node build tooling"
        }

        // 5. macOS system service (strong signal is the exe path, not just launchd).
        if anyPath("/usr/libexec") || anyPath("/system/") || anyPath("/usr/sbin") {
            return "macOS system service"
        }

        // 6. Terminal job (ppid chain hits a shell / terminal app).
        if anyAncestor(["tmux", "zsh", "bash", "fish", "terminal", "iterm", "login"]) {
            return "Started from your terminal"
        }

        // 7. Honest fallback.
        return "Started by \(first.parentName) — \(first.path)"
    }

    /// The original-cased ancestor name matching one of the needles (for the label).
    private static func ancestorMatching(_ rows: [ProcessDetail], _ needles: [String]) -> String? {
        for row in rows {
            for name in [row.parentName, row.grandparentName] where !name.isEmpty {
                let lower = name.lowercased()
                if needles.contains(where: { lower.contains($0) }) { return name }
            }
        }
        return nil
    }

    /// A friendly browser name if any ancestor is a known browser.
    private static func browserAncestor(_ rows: [ProcessDetail]) -> String? {
        let known: [(needle: String, label: String)] = [
            ("chrome", "Chrome"), ("safari", "Safari"), ("firefox", "Firefox"),
            ("brave", "Brave"), ("microsoft edge", "Edge"), ("arc", "Arc")
        ]
        let ancestors = rows.flatMap { [$0.parentName, $0.grandparentName] }.map { $0.lowercased() }
        for entry in known where ancestors.contains(where: { $0.contains(entry.needle) }) {
            return entry.label
        }
        return nil
    }
}

struct GPUSnapshot {
    var deviceUtilization: Double = 0
    var inUseMemory: UInt64 = 0
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
    case memory
    case network
}

struct MonitorSamplingPlan {
    static let memoryRefreshInterval: TimeInterval = 3
    static let networkRefreshInterval: TimeInterval = 30
    static let pressureRefreshInterval: TimeInterval = 30

    static func jobs(isVisible: Bool, mode: MonitorMode) -> Set<MonitorJob> {
        guard isVisible else { return [] }

        switch mode {
        case .memory:
            return [.memory]
        case .network:
            return [.network]
        case .cpu:
            return []
        }
    }
}

struct MemoryStatsSnapshot {
    var memory = MemorySnapshot()
    var gpu = GPUSnapshot()
    var pressure: Double?
    var pressureHistory: [Double] = []
    var lastUpdated: Date?
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


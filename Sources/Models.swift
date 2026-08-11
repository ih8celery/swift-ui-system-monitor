import AppKit
import Darwin
import Foundation
import SwiftUI

enum MonitorMode: String, CaseIterable, Identifiable {
    case power = "Power"
    case developer = "Dev"
    case memory = "Memory"
    case disk = "Disk"
    case network = "Network"
    case cpu = "CPU"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .power: return "bolt.heart"
        case .developer: return "terminal"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "arrow.up.arrow.down"
        case .cpu: return "cpu"
        }
    }
}

/// Whether a background sample came back clean, decoupled from the human-readable status text
/// shown next to it — so UI coloring never depends on matching that text verbatim.
enum SampleHealth {
    case ok
    case degraded

    init(isOK: Bool) {
        self = isOK ? .ok : .degraded
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

struct ProcessSnapshot: Identifiable {
    var id: String { name }
    let name: String
    let count: Int
    let physical: UInt64
    let virtualSize: UInt64
    let cpu: Double
}

/// Turns `ps` pcpu (a percentage of a *single* core) into a whole-machine
/// 0-100 percentage so per-process numbers share the headline's denominator.
enum ProcessCPUScale {
    /// Summed pcpu divided by the active core count.
    /// `grep` at 89% of one core on 8 cores -> ~11%; `clang (26)` summing to 620% -> ~78%.
    static func wholeMachinePercent(summedPcpu: Double, coreCount: Int) -> Double {
        guard coreCount > 0 else { return 0 }
        return summedPcpu / Double(coreCount)
    }

    /// Absolute share of the machine as a 0-1 bar fraction (not a rank against other rows).
    static func barFraction(wholeMachinePercent: Double) -> Double {
        min(max(wholeMachinePercent / 100, 0), 1)
    }
}

/// One row of the on-demand `ps` snapshot taken when a process group is tapped.
struct PidRecord {
    let pid: Int32
    let ppid: Int32
    let cpu: Double        // raw `ps` pcpu (percent of a single core)
    let memory: UInt64     // bytes
    let etime: String      // ps ELAPSED, e.g. "00:10:00" or "3-04:05:06"
    let path: String       // executable path (first token of args)
    let args: String       // full command line
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
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

struct PowerContributor: Identifiable {
    var id: String { name }
    let name: String
    let evidence: String
}

struct PowerSnapshot {
    var powerSource = "Unknown"
    var thermalState = "Unknown"
    var batteryPercent: Int?
    var isCharging: Bool?
    var sleepAssertions: [String] = []
    var contributors: [PowerContributor] = []
    var status = "Waiting for power sample"
    var health = SampleHealth.degraded
    var lastUpdated: Date?
}

struct DeveloperPort: Identifiable {
    var id: String { "\(process)|\(pid)|\(port)|\(localAddress)" }
    let process: String
    let pid: Int
    let port: String
    let localAddress: String
}

struct DeveloperProcess: Identifiable {
    var id: String { name }
    let name: String
    let kind: String
    let count: Int
    let cpu: Double
    let memory: UInt64
    let networkRate: Double
}

struct DeveloperSnapshot {
    var ports: [DeveloperPort] = []
    var processes: [DeveloperProcess] = []
    var optionalServices: [String] = []
    var status = "Waiting for developer sample"
    var health = SampleHealth.degraded
    var lastUpdated: Date?
}

struct DiskVolume: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let total: UInt64
    let free: UInt64
    let purgeable: UInt64
    let isRoot: Bool

    /// What Finder calls available: genuinely free space plus space macOS can reclaim on demand.
    var importantAvailable: UInt64 { free &+ purgeable }

    var used: UInt64 {
        total > importantAvailable ? total - importantAvailable : 0
    }

    var availableRatio: Double {
        Double(importantAvailable) / Double(max(total, 1))
    }
}

struct DiskHog: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let size: UInt64
    let hint: String
}

struct DiskSnapshot {
    var volumes: [DiskVolume] = []
    var hogs: [DiskHog] = []
    var localSnapshotCount = 0
    var status = "Waiting for disk sample"
    var health = SampleHealth.degraded
    var hogStatus = "Reclaimable paths not scanned yet"
    var isScanningHogs = false
    var lastUpdated: Date?
    var lastHogScan: Date?

    var boot: DiskVolume? {
        volumes.first(where: \.isRoot)
    }

    var otherVolumes: [DiskVolume] {
        volumes.filter { !$0.isRoot }
    }

    var maxHogSize: UInt64 {
        max(hogs.map(\.size).max() ?? 1, 1)
    }

    /// Candidates may nest (CocoaPods lives inside User Caches), so only paths with no measured
    /// ancestor contribute; counting both would bill the same bytes twice.
    var reclaimableTotal: UInt64 {
        let paths = hogs.map(\.path)
        return hogs
            .filter { hog in !paths.contains { $0 != hog.path && hog.path.hasPrefix("\($0)/") } }
            .reduce(0) { $0 &+ $1.size }
    }
}

/// A path worth measuring because it grows without being asked and can be deleted without losing work.
struct DiskHogCandidate {
    let name: String
    /// Absolute when it starts with "/", otherwise resolved against the home directory.
    let path: String
    let hint: String

    static let all: [DiskHogCandidate] = [
        DiskHogCandidate(name: "Xcode DerivedData", path: "Library/Developer/Xcode/DerivedData", hint: "Build intermediates. Safe to delete; next build is slower."),
        DiskHogCandidate(name: "Xcode Archives", path: "Library/Developer/Xcode/Archives", hint: "Shipped build archives. Keep only what you may resubmit."),
        DiskHogCandidate(name: "iOS Simulators", path: "Library/Developer/CoreSimulator", hint: "Simulator runtimes and devices. Prune with xcrun simctl delete unavailable."),
        DiskHogCandidate(name: "Xcode Device Support", path: "Library/Developer/Xcode/iOS DeviceSupport", hint: "Per-iOS-version symbols. Old versions are dead weight."),
        DiskHogCandidate(name: "Docker", path: "Library/Containers/com.docker.docker", hint: "Docker.raw disk image. Reclaim with docker system prune."),
        DiskHogCandidate(name: "User Caches", path: "Library/Caches", hint: "App caches. Safe to delete; apps refill what they need."),
        DiskHogCandidate(name: "Downloads", path: "Downloads", hint: "Usually the cheapest space to reclaim."),
        DiskHogCandidate(name: "Trash", path: ".Trash", hint: "Not free until emptied."),
        DiskHogCandidate(name: "npm Cache", path: ".npm", hint: "Package cache. Reclaim with npm cache clean --force."),
        DiskHogCandidate(name: "Cargo", path: ".cargo", hint: "Rust registry and build cache."),
        DiskHogCandidate(name: "Gradle", path: ".gradle", hint: "Android/JVM build cache."),
        DiskHogCandidate(name: "Maven", path: ".m2", hint: "JVM dependency cache."),
        DiskHogCandidate(name: "Go Modules", path: "go/pkg", hint: "Module cache. Reclaim with go clean -modcache."),
        DiskHogCandidate(name: "Expo", path: ".expo", hint: "Expo build and asset cache."),
        DiskHogCandidate(name: "CocoaPods", path: "Library/Caches/CocoaPods", hint: "Pod spec and source cache."),
        DiskHogCandidate(name: "System Caches", path: "/Library/Caches", hint: "Shared caches. Safe to delete; may need admin rights."),
    ]

    func resolvedPath(homeDirectory: String) -> String {
        path.hasPrefix("/") ? path : "\(homeDirectory)/\(path)"
    }
}

enum MonitorJob: Hashable {
    case memory
    case processes
    case network
    case power
    case developer
    case disk
}

struct MonitorSamplingPlan {
    static let fastRefreshInterval: TimeInterval = 1
    static let memoryRefreshInterval: TimeInterval = 3
    static let processRefreshInterval: TimeInterval = 10
    static let networkRefreshInterval: TimeInterval = 30
    static let powerRefreshInterval: TimeInterval = 60
    static let developerRefreshInterval: TimeInterval = 60
    static let pressureRefreshInterval: TimeInterval = 30
    static let diskRefreshInterval: TimeInterval = 30
    /// `du` walks real directory trees, so it runs far less often than the capacity read it ships with.
    static let diskHogRefreshInterval: TimeInterval = 600
    /// Per-tree ceiling. Generous, because a cold DerivedData or CoreSimulator walk is slow,
    /// but bounded so one pathological tree cannot hold the whole scan open.
    static let diskHogPathTimeout: TimeInterval = 45
    /// Whole-scan ceiling, kept well under the refresh interval so scans never overlap.
    static let diskHogScanBudget: TimeInterval = 240

    static func jobs(isVisible: Bool, mode: MonitorMode) -> Set<MonitorJob> {
        guard isVisible else { return [] }

        switch mode {
        case .power:
            return [.power, .processes]
        case .developer:
            return [.developer, .processes, .network]
        case .memory:
            return [.memory, .processes]
        case .disk:
            return [.disk]
        case .network:
            return [.network]
        case .cpu:
            return [.processes]
        }
    }
}

struct BoundedHistory {
    static func append(_ value: Double, to values: inout [Double], limit: Int) {
        values.append(value)
        let overflow = values.count - limit
        if overflow > 0 {
            values.removeFirst(overflow)
        }
    }
}

struct FastStatsSnapshot {
    var currentDownloadRate: Double = 0
    var currentUploadRate: Double = 0
    var cpuUsagePercent: Double = 0
    var cpuHistory: [Double] = []
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
}

struct MemoryStatsSnapshot {
    var memory = MemorySnapshot()
    var gpu = GPUSnapshot()
    var pressure: Double?
    var pressureHistory: [Double] = []
    var lastUpdated: Date?
}

struct ProcessSummary {
    var totalCount = 0
    var topMemory: [ProcessSnapshot] = []
    var topCPU: [ProcessSnapshot] = []
    var maxPhysical: UInt64 = 1

    init() {}

    init(rows: [ProcessSnapshot], limit: Int) {
        self.init(rows: rows, memoryLimit: limit, cpuLimit: limit)
    }

    init(
        rows: [ProcessSnapshot],
        memoryLimit: Int = UnifiedMonitor.processMemoryDisplayLimit,
        cpuLimit: Int = UnifiedMonitor.processCPUDisplayLimit
    ) {
        totalCount = rows.count
        topMemory = Array(rows.sorted { $0.physical > $1.physical }.prefix(memoryLimit))
        topCPU = Array(rows.sorted { $0.cpu > $1.cpu }.prefix(cpuLimit))
        maxPhysical = max(rows.map(\.physical).max() ?? 1, 1)
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

struct RawProcessSample {
    let pid: Int32
    let rss: UInt64
    let virtualSize: UInt64
    let cpu: Double
    let name: String
}

struct CPUCounters {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var active: UInt64 {
        user + system + nice
    }

    var total: UInt64 {
        active + idle
    }
}

struct NetworkCounters {
    let received: UInt64
    let sent: UInt64
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


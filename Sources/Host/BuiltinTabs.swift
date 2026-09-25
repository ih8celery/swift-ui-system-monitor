import Foundation
import SwiftUI
import SystemBarKit

/// What a fresh plugins.json lists, in today's tab order. Power is a bundle in PlugIns; the
/// other five are still compiled in until Stage 3.
enum DefaultPlugins {
    static let names = ["Power.bundle", "Dev.bundle", "Memory.bundle", "Disk.bundle", "Network.bundle", "CPU.bundle"]
}

/// Stage 1 of the plugin conversion: the six tabs still compile into the app and still read the
/// one `UnifiedMonitor`, but the window only knows them through `TabPlugin`. This protocol is
/// the seam that lets the monitor keep its own sampling rule (`MonitorSamplingPlan.jobs`) until
/// each tab moves out; it is deleted with `UnifiedMonitor`.
protocol MonitorBackedTab: TabPlugin {
    var monitorMode: MonitorMode { get }
}

struct BuiltinTabSource: TabSource {
    /// One row per built-in, in today's tab order, keyed by the bundle name each tab will have
    /// once it is a real bundle, so a plugins.json written today is still right then.
    static let builtins: [(name: String, type: TabPlugin.Type)] = [
        ("Dev.bundle", DevTab.self),
        ("Memory.bundle", MemoryTab.self),
        ("Network.bundle", NetworkTab.self),
        ("CPU.bundle", CPUTab.self),
    ]

    static let types = Dictionary(uniqueKeysWithValues: builtins.map { ($0.name, $0.type) })

    /// True when a compiled-in tab has this name, so callers do not need the static table.
    func has(named name: String) -> Bool {
        Self.types[name] != nil
    }

    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type {
        guard let name = entry.name else {
            throw TabLoadError(description: "only the compiled-in tabs can be found by name; a \"path\" entry is a bundle")
        }
        guard let type = Self.types[name] else {
            let known = Self.types.keys.sorted().joined(separator: ", ")
            throw TabLoadError(description: "no compiled-in tab is named \"\(name)\"; the names are \(known)")
        }
        return type
    }
}

// Each adapter's refreshInterval restates MonitorSamplingPlan's interval for that tab; its
// sharedFeeds are what HostSamplers reads to decide which shared samplers run while it is
// visible, exactly as for a bundle.

final class DevTab: MonitorBackedTab {
    static let identifier = "dev"
    let title = "Dev"
    let systemImage = "terminal"
    let accent = Palette.purple
    let refreshInterval = MonitorSamplingPlan.capacityRefreshInterval
    let sharedFeeds: Set<SharedFeed> = []
    let monitorMode = MonitorMode.developer

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(DeveloperPanel(monitor: .shared)) }
}

final class MemoryTab: MonitorBackedTab {
    static let identifier = "memory"
    let title = "Memory"
    let systemImage = "memorychip"
    let accent = Palette.good
    let refreshInterval = MonitorSamplingPlan.memoryRefreshInterval
    let sharedFeeds: Set<SharedFeed> = [.processes]
    let monitorMode = MonitorMode.memory

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(MemoryPanel(monitor: .shared)) }
}

final class NetworkTab: MonitorBackedTab {
    static let identifier = "network"
    let title = "Network"
    let systemImage = "arrow.up.arrow.down"
    let accent = Palette.blue
    let refreshInterval = MonitorSamplingPlan.networkRefreshInterval
    let sharedFeeds: Set<SharedFeed> = [.fastStats]
    let monitorMode = MonitorMode.network

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(NetworkPanel(monitor: .shared)) }
}

final class CPUTab: MonitorBackedTab {
    static let identifier = "cpu"
    let title = "CPU"
    let systemImage = "cpu"
    let accent = Palette.warning
    let refreshInterval = HostSamplers.processInterval
    let sharedFeeds: Set<SharedFeed> = [.processes, .fastStats]
    let monitorMode = MonitorMode.cpu

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(CPUPanel(monitor: .shared)) }
}

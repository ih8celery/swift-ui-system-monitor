import Foundation
import SwiftUI
import SystemBarKit

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
        ("Power.bundle", PowerTab.self),
        ("Dev.bundle", DevTab.self),
        ("Memory.bundle", MemoryTab.self),
        ("Disk.bundle", DiskTab.self),
        ("Network.bundle", NetworkTab.self),
        ("CPU.bundle", CPUTab.self),
    ]

    /// The order a fresh plugins.json lists them in.
    static let defaultNames = builtins.map(\.name)

    static let types = Dictionary(uniqueKeysWithValues: builtins.map { ($0.name, $0.type) })

    @MainActor func makeTab(for entry: PluginEntry, host: HostServices) throws -> TabPlugin {
        guard let name = entry.name else {
            throw TabLoadError(description: "\"path\" entries are not supported yet; only the built-in tabs can be listed, by \"name\"")
        }
        guard let type = Self.types[name] else {
            let known = Self.types.keys.sorted().joined(separator: ", ")
            throw TabLoadError(description: "no built-in tab is named \"\(name)\"; the names are \(known)")
        }
        return type.init(host: host)
    }
}

// Each adapter's refreshInterval and sharedFeeds restate what MonitorSamplingPlan says about
// that tab today, plus the 1-second fast feed wherever the panel reads it (today that feed runs
// for every visible tab, so the plan never lists it). Nothing reads them yet; the host scheduler
// that will arrives in Stage 2.

final class PowerTab: MonitorBackedTab {
    static let identifier = "power"
    let title = "Power"
    let systemImage = "bolt.heart"
    let accent = Palette.caution
    let refreshInterval = MonitorSamplingPlan.powerRefreshInterval
    let sharedFeeds: Set<SharedFeed> = [.processes]
    let monitorMode = MonitorMode.power

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(PowerPanel(monitor: .shared)) }
}

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

final class DiskTab: MonitorBackedTab {
    static let identifier = "disk"
    let title = "Disk"
    let systemImage = "internaldrive"
    let accent = Palette.cyan
    let refreshInterval = MonitorSamplingPlan.diskRefreshInterval
    let sharedFeeds: Set<SharedFeed> = []
    let monitorMode = MonitorMode.disk

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(DiskPanel(monitor: .shared)) }
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
    let refreshInterval = MonitorSamplingPlan.processRefreshInterval
    let sharedFeeds: Set<SharedFeed> = [.processes, .fastStats]
    let monitorMode = MonitorMode.cpu

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(CPUPanel(monitor: .shared)) }
}

import Foundation
import SwiftUI

/// A shared sampler the host runs on a plugin's behalf while that plugin's tab is showing.
/// Declaring one is what starts it; nothing starts by being read.
public enum SharedFeed: Hashable, Sendable {
    /// The 10-second `ps` summary: top processes by CPU and by memory, and counts.
    case processes
    /// The 1-second CPU and network counters and their histories.
    case fastStats
}

/// One tab. The host creates a plugin once at launch, calls `collect()` on the plugin's own
/// queue only while its tab is on screen, and embeds `makeView()` in the window.
///
/// Thread rules, fixed for every plugin built against this SDK: the host constructs every
/// plugin on the main thread at launch; `collect()` runs on a queue the host owns for this
/// plugin, never concurrently with itself; `makeView()` and `visibilityChanged(isVisible:)` run
/// on the main thread; a plugin that publishes from `collect()` hops to the main thread first,
/// because the panel observes it from there.
public protocol TabPlugin: AnyObject {
    /// Stable, unique, lowercase. Two loaded plugins sharing one is an error the host shows.
    static var identifier: String { get }
    var title: String { get }
    var systemImage: String { get }
    var accent: Color { get }
    /// How often the host calls `collect()` while this tab is showing. A `collect()` that runs
    /// longer than the interval is not queued up again; missed ticks merge into the next call.
    var refreshInterval: TimeInterval { get }
    /// Which shared samplers must run while this tab is showing. The set is not frozen: a host
    /// switching over it needs `@unknown default`.
    var sharedFeeds: Set<SharedFeed> { get }

    @MainActor init(host: HostServices)
    /// This plugin's own queue, never concurrently with itself, only while visible.
    func collect()
    /// Main thread, when the tab is switched to or away from. Default: nothing.
    @MainActor func visibilityChanged(isVisible: Bool)
    /// Main thread. The panel observes the plugin's own model objects.
    @MainActor func makeView() -> AnyView
}

public extension TabPlugin {
    @MainActor func visibilityChanged(isVisible: Bool) {}
}

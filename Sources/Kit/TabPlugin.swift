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
    /// The tab's name, shown in the tab picker, e.g. "Network".
    var title: String { get }
    /// The SF Symbols name of the tab's icon, shown in the tab picker and the window header.
    var systemImage: String { get }
    /// The tab's colour: the host tints the header icon with it while this tab is selected. One
    /// of the `Palette` colours keeps it in step with the other tabs.
    var accent: Color { get }
    /// How often the host calls `collect()` while this tab is showing. A `collect()` that runs
    /// longer than the interval is not queued up again; missed ticks merge into the next call.
    var refreshInterval: TimeInterval { get }
    /// Which shared samplers must run while this tab is showing. The set is not frozen: a host
    /// switching over it needs `@unknown default`.
    var sharedFeeds: Set<SharedFeed> { get }

    /// The host times this call and logs a warning once it passes 100 ms, so slow work belongs
    /// in `collect()` instead.
    @MainActor init(host: HostServices)
    /// This plugin's own queue, never concurrently with itself, only while visible.
    func collect()
    /// Main thread, when the tab is switched to or away from. Default: nothing.
    @MainActor func visibilityChanged(isVisible: Bool)
    /// Main thread. The panel observes the plugin's own model objects.
    @MainActor func makeView() -> AnyView
}

/// Defaults, so a plugin implements only what it needs and a requirement added to the protocol
/// later does not stop an older bundle from loading.
public extension TabPlugin {
    /// Does nothing: most plugins need no notice beyond `collect()` starting and stopping.
    @MainActor func visibilityChanged(isVisible: Bool) {}
}

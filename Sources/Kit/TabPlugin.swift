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
/// queue while its tab is on screen (and, if the plugin declares a `backgroundInterval`, at that
/// cadence while it is not), and embeds `makeView()` in the window.
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
    /// How often the host calls `collect()` while this tab is NOT showing: the window closed,
    /// or open on another tab. Nil, the default, means never: the tab samples only while it is
    /// on screen, as every tab did before this existed. A number is clamped to between 5 seconds
    /// and one day, and each substitution is logged. Shared feeds run only for the window and the
    /// showing tab, never for this one while it is hidden, so a background `collect()` must sample
    /// for itself; a feed value read then is whatever the feed last held. Every wake of the Mac
    /// or its screen restarts the cadence with a tick two minutes later, so no sample lands on
    /// the login moment and a long interval still gets a tick soon after each wake: keep the
    /// work of one tick cheap, and keep any slower cadence (a scan every few hours, say) in
    /// your own bookkeeping, checked on each tick. Declare one only for work the person wants
    /// done while they are not looking, and say in the README what runs and how often.
    var backgroundInterval: TimeInterval? { get }

    /// The host times this call and logs a warning once it passes 100 ms, so slow work belongs
    /// in `collect()` instead.
    @MainActor init(host: HostServices)
    /// This plugin's own queue, never concurrently with itself: while visible, and while hidden only if `backgroundInterval` is set.
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
    /// Nil: the tab is collected only while it is showing.
    var backgroundInterval: TimeInterval? { nil }
}

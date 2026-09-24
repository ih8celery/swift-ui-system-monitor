import Foundation
import SwiftUI

/// A shared sampler the host runs on a plugin's behalf while that plugin's tab is showing.
/// Declaring one is what starts it; nothing starts by being read.
public enum SharedFeed: Hashable {
    /// The 10-second `ps` summary: top processes by CPU and by memory, and counts.
    case processes
    /// The 1-second CPU and network counters and their histories.
    case fastStats
}

/// One tab. The host creates a plugin once at launch, calls `collect()` on the plugin's own
/// queue only while its tab is on screen, and embeds `makeView()` in the window.
public protocol TabPlugin: AnyObject {
    /// Stable, unique, lowercase. Two loaded plugins sharing one is an error the host shows.
    static var identifier: String { get }
    var title: String { get }
    var systemImage: String { get }
    var accent: Color { get }
    /// How often the host calls `collect()` while this tab is showing.
    var refreshInterval: TimeInterval { get }
    /// Which shared samplers must run while this tab is showing.
    var sharedFeeds: Set<SharedFeed> { get }

    init(host: HostServices)
    /// Runs on this plugin's own queue, never concurrently with itself, only while visible.
    func collect()
    /// Main thread, when the tab is switched to or away from.
    func visibilityChanged(isVisible: Bool)
    /// Main thread. The panel observes the plugin's own model objects.
    func makeView() -> AnyView
}

public extension TabPlugin {
    func visibilityChanged(isVisible: Bool) {}
}

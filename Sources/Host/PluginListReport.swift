import Foundation
import SystemBarKit

/// What `SystemBar --list-plugins` prints: the loader's outcome, one line per enabled entry,
/// so the real loading path can be checked from a script. A plugin that samples while hidden
/// says so on its line, with the cadence the scheduler would actually run, so "the app does
/// nothing while closed except X" can be checked the same way.
enum PluginListReport {
    static func lines(for tabs: [LoadedTab]) -> [String] {
        tabs.map { tab in
            switch tab {
            case let .loaded(location, plugin):
                return "ok \(type(of: plugin).identifier) \(plugin.title) \(location)" + backgroundSuffix(for: plugin)
            case let .failed(location, reason):
                return "error \(location): \(reason)"
            }
        }
    }

    private static func backgroundSuffix(for plugin: TabPlugin) -> String {
        guard let declared = plugin.backgroundInterval else { return "" }
        return " background every \(seconds(PluginScheduler.reportedBackgroundInterval(declared)))s"
    }

    /// `60`, not `60.0`, for a whole number of seconds; one decimal otherwise.
    private static func seconds(_ interval: TimeInterval) -> String {
        interval == interval.rounded() ? String(Int(interval)) : String(format: "%.1f", interval)
    }
}

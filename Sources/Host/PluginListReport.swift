import Foundation

/// What `SystemBar --list-plugins` prints: the loader's outcome, one line per enabled entry,
/// so the real loading path can be checked from a script.
enum PluginListReport {
    static func lines(for tabs: [LoadedTab]) -> [String] {
        tabs.map { tab in
            switch tab {
            case let .loaded(location, plugin):
                return "ok \(type(of: plugin).identifier) \(plugin.title) \(location)"
            case let .failed(location, reason):
                return "error \(location): \(reason)"
            }
        }
    }
}

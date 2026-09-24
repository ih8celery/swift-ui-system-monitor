import Foundation

/// The outcome of one enabled config entry. A failure keeps its place in the tab order so the
/// window can show it where the tab would have been.
enum LoadedTab {
    case loaded(location: String, plugin: TabPlugin)
    case failed(location: String, reason: String)

    var title: String {
        switch self {
        case .loaded(_, let plugin): return plugin.title
        case .failed: return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .loaded(_, let plugin): return plugin.systemImage
        case .failed: return "exclamationmark.triangle"
        }
    }

    var plugin: TabPlugin? {
        if case .loaded(_, let plugin) = self { return plugin }
        return nil
    }
}

/// A reason a person can act on, thrown by a `TabSource`.
struct TabLoadError: Error, CustomStringConvertible {
    let description: String
}

/// Turns one config entry into a plugin, or throws. Stage 1 has one source, the built-ins;
/// Stage 2 adds the one that loads bundles.
protocol TabSource {
    func makeTab(for entry: PluginEntry, host: HostServices) throws -> TabPlugin
}

enum TabCatalog {
    /// Every enabled entry, in order, as a loaded tab or a failure. Nothing here stops on error.
    static func build(config: PluginConfig, source: TabSource, host: HostServices) -> [LoadedTab] {
        var tabs: [LoadedTab] = []
        var loadedIDs = Set<String>()
        for entry in config.plugins where entry.isEnabled {
            let tab = makeTab(for: entry, source: source, host: host, alreadyLoaded: loadedIDs)
            tabs.append(tab)
            if let plugin = tab.plugin {
                loadedIDs.insert(type(of: plugin).identifier)
            }
        }
        return tabs
    }

    private static func makeTab(
        for entry: PluginEntry,
        source: TabSource,
        host: HostServices,
        alreadyLoaded: Set<String>
    ) -> LoadedTab {
        let plugin: TabPlugin
        do {
            plugin = try source.makeTab(for: entry, host: host)
        } catch {
            return .failed(location: entry.location, reason: "\(error)")
        }
        let id = type(of: plugin).identifier
        if alreadyLoaded.contains(id) {
            return .failed(location: entry.location, reason: "another loaded plugin already has the id \"\(id)\"")
        }
        return .loaded(location: entry.location, plugin: plugin)
    }
}

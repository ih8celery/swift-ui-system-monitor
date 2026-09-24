import Foundation
import SystemBarKit

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
    @MainActor func makeTab(for entry: PluginEntry, host: HostServices) throws -> TabPlugin
}

enum TabCatalog {
    /// Every enabled entry, in order, as a loaded tab or a failure. Nothing here stops on error.
    @MainActor static func build(config: PluginConfig, source: TabSource, host: HostServices) -> [LoadedTab] {
        var tabs: [LoadedTab] = []
        // Identifier to the location of the entry that first claimed it, so a later duplicate
        // can name which earlier entry it clashes with.
        var loadedIDs: [String: String] = [:]
        for entry in config.plugins where entry.isEnabled {
            let tab = makeTab(for: entry, source: source, host: host, alreadyLoaded: loadedIDs)
            tabs.append(tab)
            if let plugin = tab.plugin {
                loadedIDs[type(of: plugin).identifier] = entry.location
            }
        }
        return tabs
    }

    @MainActor private static func makeTab(
        for entry: PluginEntry,
        source: TabSource,
        host: HostServices,
        alreadyLoaded: [String: String]
    ) -> LoadedTab {
        let plugin: TabPlugin
        do {
            plugin = try source.makeTab(for: entry, host: host)
        } catch {
            // A TabSource throws TabLoadError for its own readable reasons; anything else (an
            // NSError from Foundation, say, once a source loads real bundles) has a description
            // worth showing instead of Swift's dump of its domain/code/userInfo.
            let reason = (error as? TabLoadError)?.description ?? error.localizedDescription
            return .failed(location: entry.location, reason: reason)
        }
        let id = type(of: plugin).identifier
        if let earlierLocation = alreadyLoaded[id] {
            return .failed(
                location: entry.location,
                reason: "the id \"\(id)\" is already used by \"\(earlierLocation)\", which comes earlier in the list"
            )
        }
        return .loaded(location: entry.location, plugin: plugin)
    }
}

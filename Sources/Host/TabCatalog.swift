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

/// Turns one config entry into a plugin class, or throws. The catalog constructs it, after the
/// duplicate-id check, so a refused duplicate never runs its init.
protocol TabSource {
    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type
}

enum TabCatalog {
    /// The SDK promises `init(host:)` runs on the main thread and does no slow work, because
    /// slow work there freezes the menu bar while the window opens. This is how long an init
    /// may take before the host warns that the work belongs in `collect()` instead. The README
    /// and the spec quote this value, so change them together.
    static let slowInitThreshold: TimeInterval = 0.1

    /// Every enabled entry, in order, as a loaded tab or a failure. Nothing here stops on error.
    /// Each plugin is constructed with a host of its own: the shared feeds and runner, plus its
    /// entry's settings and a folder named by its identifier under `dataRoot`.
    @MainActor static func build(
        config: PluginConfig,
        source: TabSource,
        host: HostServices,
        dataRoot: URL = PluginDataRoot.standard()
    ) -> [LoadedTab] {
        var tabs: [LoadedTab] = []
        // Identifier to the location of the entry that first claimed it, so a later duplicate
        // can name which earlier entry it clashes with.
        var loadedIDs: [String: String] = [:]
        for entry in config.plugins where entry.isEnabled {
            let tab = makeTab(for: entry, source: source, host: host, dataRoot: dataRoot, alreadyLoaded: loadedIDs)
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
        dataRoot: URL,
        alreadyLoaded: [String: String]
    ) -> LoadedTab {
        let type: TabPlugin.Type
        do {
            type = try source.resolve(entry)
        } catch {
            // A TabSource throws TabLoadError for its own reasons; anything else (a Foundation
            // error from a bundle, say) should show its message, not Swift's dump of it.
            let reason = (error as? TabLoadError)?.description ?? error.localizedDescription
            return .failed(location: entry.location, reason: reason)
        }
        let id = type.identifier
        if let earlier = alreadyLoaded[id] {
            return .failed(location: entry.location, reason: "the id \"\(id)\" is already used by \"\(earlier)\", which comes earlier in the list")
        }
        let pluginHost = host.forPlugin(identifier: id, settings: entry.settings, dataRoot: dataRoot)
        return .loaded(location: entry.location, plugin: timedInit(of: type, host: pluginHost))
    }

    /// Constructs one plugin, timing its init(host:) and warning through the host's log when it
    /// passes `slowInitThreshold`. The plugin loads either way; this only names where the time went.
    @MainActor private static func timedInit(of type: TabPlugin.Type, host: HostServices) -> TabPlugin {
        let start = DispatchTime.now()
        let plugin = type.init(host: host)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        if elapsedSeconds > slowInitThreshold {
            let milliseconds = Int((elapsedSeconds * 1000).rounded())
            let limitMilliseconds = Int(slowInitThreshold * 1000)
            host.log("SystemBar: \(type.identifier) took \(milliseconds) ms in init(host:); the limit is \(limitMilliseconds) ms, so do slow work in collect() instead")
        }
        return plugin
    }
}

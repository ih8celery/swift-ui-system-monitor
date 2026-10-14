import Foundation
import SystemBarKit

/// What a fresh plugins.json lists: nothing. The app ships no tabs; each tab repository's
/// installer adds its own by path. A name entry still resolves to a bundle in the app's
/// Contents/PlugIns, which is empty unless someone puts one there.
enum DefaultPlugins {
    static let names: [String] = []
}

/// What the app does at launch, in one testable place: read (or create) plugins.json, then
/// build the tab list. A file that cannot be read, parsed, or written gives one error tab
/// naming the path and the reason, and nothing else: the fix is in the file, not the app.
enum TabLoader {
    @MainActor static func load(store: PluginConfigStore, source: TabSource, host: HostServices, dataRoot: URL) -> [LoadedTab] {
        switch store.loadOrCreate(default: .defaults(named: DefaultPlugins.names)) {
        case .success(let config):
            return TabCatalog.build(config: config, source: source, host: host, dataRoot: dataRoot)
        case .failure(let error):
            return [.failed(location: store.fileURL.path, reason: error.description)]
        }
    }
}

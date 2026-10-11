import Foundation
import SystemBarKit

/// What a fresh plugins.json lists, in the tab order the app has always had. Each is a bundle in
/// the app's Contents/PlugIns. This is the default file's content, not a list the host treats
/// specially: a tab removed from plugins.json is gone, like any other.
enum DefaultPlugins {
    static let names = ["Power.bundle", "Dev.bundle", "Memory.bundle", "Disk.bundle", "Network.bundle", "CPU.bundle"]
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

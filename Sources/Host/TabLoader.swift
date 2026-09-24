import Foundation

/// What the app does at launch, in one testable place: read (or create) plugins.json, then
/// build the tab list. A file that cannot be read, parsed, or written gives one error tab
/// naming the path and the reason, and nothing else: the fix is in the file, not the app.
enum TabLoader {
    static func load(store: PluginConfigStore, source: TabSource, host: HostServices) -> [LoadedTab] {
        switch store.loadOrCreate(default: .builtins(named: BuiltinTabSource.defaultNames)) {
        case .success(let config):
            return TabCatalog.build(config: config, source: source, host: host)
        case .failure(let error):
            return [.failed(location: store.fileURL.path, reason: error.description)]
        }
    }
}

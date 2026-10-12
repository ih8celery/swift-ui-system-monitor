import Foundation
import SystemBarKit

/// Loads one bundle exactly as the menu bar would load a `"path"` entry of plugins.json, through
/// the same catalog (and so the same name checks, init timing and per-plugin host), but from a
/// list of one held in memory, so the real plugins.json is never read or written.
enum PreviewSession {
    @MainActor static func load(
        bundlePath: String,
        settings: PluginSettings,
        source: TabSource,
        host: HostServices,
        dataRoot: URL
    ) -> LoadedTab {
        let entry = PluginEntry(name: nil, path: bundlePath, isEnabled: true, settings: settings)
        let tabs = TabCatalog.build(config: PluginConfig(plugins: [entry]), source: source, host: host, dataRoot: dataRoot)
        return tabs[0]
    }
}

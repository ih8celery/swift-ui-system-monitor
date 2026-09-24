import Foundation
import SystemBarKit

/// Stage 2's loader: a name whose bundle exists in PlugIns loads as a bundle; a name with no
/// bundle falls back to the tabs still compiled into the app; a path is always a bundle.
/// Deleted in Stage 3 along with BuiltinTabSource, leaving BundleTabSource alone.
struct HostTabSource: TabSource {
    let bundles: BundleTabSource
    let builtins: BuiltinTabSource

    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type {
        if let name = entry.name, !bundles.hasBundle(named: name), BuiltinTabSource.types[name] != nil {
            return try builtins.resolve(entry)
        }
        return try bundles.resolve(entry)
    }
}

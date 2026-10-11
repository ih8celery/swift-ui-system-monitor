import Foundation

/// Where plugins keep their own files: one folder per plugin identifier under this root.
/// `SYSTEMBAR_PLUGIN_DATA_ROOT` moves the root, so tests and scripts never write into the real
/// Application Support folder. The name is not `Plugins` because the folder users install bundles
/// into is `SystemBar/PlugIns`, and on a case-insensitive filesystem (the macOS default) the two
/// would be one folder, mixing plugin state with installable bundles.
enum PluginDataRoot {
    static let environmentOverride = "SYSTEMBAR_PLUGIN_DATA_ROOT"
    static let relativePath = "SystemBar/PluginData"

    static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        if let override = environment[environmentOverride], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent(relativePath, isDirectory: true)
    }
}

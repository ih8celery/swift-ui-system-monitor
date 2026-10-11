import Foundation

/// Where plugins keep their own files: one folder per plugin identifier under this root.
/// `SYSTEMBAR_PLUGIN_DATA_ROOT` moves the root, so tests and scripts never write into the real
/// Application Support folder.
enum PluginDataRoot {
    static let environmentOverride = "SYSTEMBAR_PLUGIN_DATA_ROOT"
    static let relativePath = "SystemBar/Plugins"

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

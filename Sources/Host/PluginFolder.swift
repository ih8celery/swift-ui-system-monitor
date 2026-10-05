import Foundation

/// The shared folder other projects install their plugin bundles into, beside plugins.json, so a
/// tab can be added without anyone editing that file.
enum PluginFolder {
    static let environmentOverride = "SYSTEMBAR_PLUGINS_DIR"
    static let relativePath = "SystemBar/PlugIns"

    /// `~/Library/Application Support/SystemBar/PlugIns`, unless SYSTEMBAR_PLUGINS_DIR points
    /// somewhere else. The override exists so tests and scripts can run the app against a folder
    /// of their own without touching the real one, as SYSTEMBAR_PLUGINS_FILE does for the file.
    static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        if let override = environment[environmentOverride], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return applicationSupport.appendingPathComponent(relativePath)
    }
}

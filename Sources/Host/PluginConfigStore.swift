import Foundation

/// Where plugins.json lives, and how it is first written and then read.
struct PluginConfigStore {
    static let environmentOverride = "SYSTEMBAR_PLUGINS_FILE"
    static let relativePath = "SystemBar/plugins.json"

    let fileURL: URL

    /// `~/Library/Application Support/SystemBar/plugins.json`, unless SYSTEMBAR_PLUGINS_FILE
    /// points somewhere else. The override exists so tests and scripts can run the app against a
    /// file of their own without touching the real one.
    static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> PluginConfigStore {
        if let override = environment[environmentOverride], !override.isEmpty {
            return PluginConfigStore(fileURL: URL(fileURLWithPath: override))
        }
        return PluginConfigStore(fileURL: applicationSupport.appendingPathComponent(relativePath))
    }

    /// Reads the file, or writes the given default and returns it when there is no file yet.
    func loadOrCreate(default config: PluginConfig) -> Result<PluginConfig, PluginConfigError> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            do {
                try write(config)
            } catch {
                return .failure(.unwritable(error.localizedDescription))
            }
            return .success(config)
        }
        return load()
    }

    func load() -> Result<PluginConfig, PluginConfigError> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        return PluginConfigParser.parse(data)
    }

    /// Writes atomically, with a trailing newline, since the file is meant to be hand-edited.
    func write(_ config: PluginConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PluginConfigParser.encode(config) + Data("\n".utf8)
        try data.write(to: fileURL, options: .atomic)
    }
}

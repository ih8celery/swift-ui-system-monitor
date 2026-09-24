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
            return PluginConfigStore(fileURL: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        return PluginConfigStore(fileURL: applicationSupport.appendingPathComponent(relativePath))
    }

    /// Reads the file, or writes the given default and returns it when there is no file yet.
    /// Reading first, rather than checking for the file and then writing, means a file that
    /// exists but cannot be read is reported as exactly that, never overwritten.
    func loadOrCreate(default config: PluginConfig) -> Result<PluginConfig, PluginConfigError> {
        switch read() {
        case .success(let data):
            return PluginConfigParser.parse(data)
        case .failure(.notFound):
            do {
                try write(config)
            } catch {
                return .failure(.unwritable(error.localizedDescription))
            }
            return .success(config)
        case .failure(.unreadable(let reason)):
            return .failure(.unreadable(reason))
        }
    }

    func load() -> Result<PluginConfig, PluginConfigError> {
        switch read() {
        case .success(let data):
            return PluginConfigParser.parse(data)
        case .failure(.notFound):
            return .failure(.unreadable("there is no file at \(fileURL.path)"))
        case .failure(.unreadable(let reason)):
            return .failure(.unreadable(reason))
        }
    }

    private enum ReadFailure: Error {
        case notFound
        case unreadable(String)
    }

    /// Foundation's own message for a folder at the path is "couldn't be opened", which does not
    /// say why, so that case gets its own sentence.
    private func read() -> Result<Data, ReadFailure> {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .failure(.unreadable("\(fileURL.path) is a folder, not a file"))
        }
        do {
            return .success(try Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            return .failure(.notFound)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    /// Writes atomically, with a trailing newline, since the file is meant to be hand-edited.
    func write(_ config: PluginConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PluginConfigParser.encode(config) + Data("\n".utf8)
        try data.write(to: fileURL, options: .atomic)
    }
}

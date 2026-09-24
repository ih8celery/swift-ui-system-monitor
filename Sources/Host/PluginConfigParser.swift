import Foundation

/// Reads and writes plugins.json. Uses JSONSerialization rather than Codable because the file
/// is hand-edited: an unknown key or a wrong type must be an error that names its place, and
/// Codable ignores unknown keys silently. What JSONSerialization cannot see, this cannot either:
/// a duplicate key keeps its first value, and a trailing comma is accepted.
enum PluginConfigParser {
    private static let topLevel = "the top level"
    private static let topLevelKeys: Set<String> = ["plugins"]
    private static let entryKeys: Set<String> = ["name", "path", "enabled"]
    /// Foundation's own userInfo key for the byte offset a parse failed at. Named by string
    /// because the constant is not exposed to Swift on every SDK.
    private static let errorIndexKey = "NSJSONSerializationErrorIndex"

    static func parse(_ data: Data) -> Result<PluginConfig, PluginConfigError> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.malformedJSON(malformedDetail(from: error as NSError, in: data)))
        }
        guard let root = object as? [String: Any] else {
            return .failure(.notAnObject(where: topLevel))
        }
        if let unknown = root.keys.sorted().first(where: { !topLevelKeys.contains($0) }) {
            return .failure(.unknownKey(unknown, where: topLevel))
        }
        guard let rawPlugins = present(root["plugins"]) else {
            return .failure(.missingKey("plugins", where: topLevel))
        }
        guard let rawEntries = rawPlugins as? [Any] else {
            return .failure(.wrongType(key: "plugins", expected: "a list", where: topLevel))
        }
        var entries: [PluginEntry] = []
        for (index, raw) in rawEntries.enumerated() {
            switch parseEntry(raw, where: "plugins[\(index)]") {
            case .success(let entry):
                entries.append(entry)
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(PluginConfig(plugins: entries))
    }

    /// The byte offset Foundation reports, turned into a line number this code owns. The debug
    /// description's wording has changed between macOS releases; a count of newlines has not. On
    /// current macOS, Foundation's own text already says "around line N, column M", so the
    /// "line N: " prefix is added only when the text does not already mention a line, to avoid
    /// saying it twice.
    private static func malformedDetail(from error: NSError, in data: Data) -> String {
        let text = error.userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        guard let offset = error.userInfo[errorIndexKey] as? Int, offset >= 0, offset <= data.count else {
            return text
        }
        guard !text.contains("line") else {
            return text
        }
        let line = data.prefix(offset).filter { $0 == UInt8(ascii: "\n") }.count + 1
        return "line \(line): \(text)"
    }

    /// JSON `null` arrives as NSNull. For a location key it means the same as leaving the key
    /// out; for `enabled` it is not a boolean and is rejected like any other wrong type.
    private static func present(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }

    private static func parseEntry(_ raw: Any, where place: String) -> Result<PluginEntry, PluginConfigError> {
        guard let object = raw as? [String: Any] else {
            return .failure(.notAnObject(where: place))
        }
        if let unknown = object.keys.sorted().first(where: { !entryKeys.contains($0) }) {
            return .failure(.unknownKey(unknown, where: place))
        }
        let name = present(object["name"])
        let path = present(object["path"])
        if name != nil, path != nil {
            return .failure(.entryHasBoth(where: place))
        }
        if name == nil, path == nil {
            return .failure(.entryNeedsNameOrPath(where: place))
        }
        if let name, !(name is String) {
            return .failure(.wrongType(key: "name", expected: "a string", where: place))
        }
        if let path, !(path is String) {
            return .failure(.wrongType(key: "path", expected: "a string", where: place))
        }
        return parseEnabled(object["enabled"], where: place).map { isEnabled in
            PluginEntry(name: name as? String, path: path as? String, isEnabled: isEnabled)
        }
    }

    private static func parseEnabled(_ raw: Any?, where place: String) -> Result<Bool, PluginConfigError> {
        guard let raw else { return .success(true) }
        guard isBoolean(raw), let value = raw as? Bool else {
            return .failure(.wrongType(key: "enabled", expected: "true or false", where: place))
        }
        return .success(value)
    }

    /// JSONSerialization hands back NSNumber for both `1` and `true`; only the latter is a boolean.
    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func encode(_ config: PluginConfig) throws -> Data {
        let entries = config.plugins.map(object(for:))
        return try JSONSerialization.data(
            withJSONObject: ["plugins": entries],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// `enabled` is written only when false, since true is the default a reader assumes.
    private static func object(for entry: PluginEntry) -> [String: Any] {
        let location: [String: Any]
        if let name = entry.name {
            location = ["name": name]
        } else if let path = entry.path {
            location = ["path": path]
        } else {
            location = [:]
        }
        return entry.isEnabled ? location : location.merging(["enabled": false]) { current, _ in current }
    }
}

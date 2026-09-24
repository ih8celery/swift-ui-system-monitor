import Foundation

/// Reads and writes plugins.json. Uses JSONSerialization rather than Codable because the file
/// is hand-edited: an unknown key or a wrong type must be an error that names its place, and
/// Codable ignores unknown keys silently.
enum PluginConfigParser {
    private static let topLevelKeys: Set<String> = ["plugins"]
    private static let entryKeys: Set<String> = ["name", "path", "enabled"]

    static func parse(_ data: Data) -> Result<PluginConfig, PluginConfigError> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            return .failure(.malformedJSON(detail))
        }
        guard let root = object as? [String: Any] else {
            return .failure(.notAnObject(where: "the top level"))
        }
        if let unknown = root.keys.sorted().first(where: { !topLevelKeys.contains($0) }) {
            return .failure(.unknownKey(unknown, where: "the top level"))
        }
        guard let rawEntries = root["plugins"] as? [Any] else {
            return .failure(.wrongType(key: "plugins", expected: "a list", where: "the top level"))
        }
        let empty = Result<PluginConfig, PluginConfigError>.success(PluginConfig(plugins: []))
        return rawEntries.enumerated().reduce(into: empty) { result, indexed in
            guard case .success(let soFar) = result else { return }
            switch parseEntry(indexed.element, where: "plugins[\(indexed.offset)]") {
            case .success(let entry):
                result = .success(PluginConfig(plugins: soFar.plugins + [entry]))
            case .failure(let error):
                result = .failure(error)
            }
        }
    }

    private static func parseEntry(_ raw: Any, where place: String) -> Result<PluginEntry, PluginConfigError> {
        guard let object = raw as? [String: Any] else {
            return .failure(.notAnObject(where: place))
        }
        if let unknown = object.keys.sorted().first(where: { !entryKeys.contains($0) }) {
            return .failure(.unknownKey(unknown, where: place))
        }
        let name = object["name"]
        let path = object["path"]
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
        return try JSONSerialization.data(withJSONObject: ["plugins": entries], options: [.prettyPrinted, .sortedKeys])
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

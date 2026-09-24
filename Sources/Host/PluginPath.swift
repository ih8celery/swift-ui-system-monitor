import Foundation

/// Where a config entry points. A name stays inside the app's own PlugIns folder; a path is
/// absolute or starts with `~/`. Anything else is refused before Bundle sees it.
enum PluginPath {
    static func resolve(_ entry: PluginEntry, builtInPlugInsURL: URL?, homeDirectory: String) throws -> URL {
        if let name = entry.name {
            return try resolveName(name, builtInPlugInsURL: builtInPlugInsURL)
        }
        return try resolvePath(entry.path ?? "", homeDirectory: homeDirectory)
    }

    static func resolveName(_ name: String, builtInPlugInsURL: URL?) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw TabLoadError(description: "the name \"\(name)\" is not a single file name; a name is a bundle inside the app's PlugIns folder, and anything else needs \"path\"")
        }
        guard let folder = builtInPlugInsURL else {
            throw TabLoadError(description: "this build of SystemBar has no PlugIns folder, so \"\(name)\" cannot be found by name")
        }
        return folder.appendingPathComponent(name)
    }

    private static func resolvePath(_ path: String, homeDirectory: String) throws -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: homeDirectory).appendingPathComponent(String(path.dropFirst(2)))
        }
        throw TabLoadError(description: "the path \"\(path)\" must be absolute or start with ~/")
    }
}

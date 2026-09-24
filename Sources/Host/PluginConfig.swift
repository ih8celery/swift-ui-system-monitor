import Foundation

/// One line of plugins.json. Exactly one of `name` (a bundle shipped inside the app) or `path`
/// (a bundle anywhere on disk) is set; the parser refuses anything else.
struct PluginEntry: Equatable {
    let name: String?
    let path: String?
    let isEnabled: Bool

    /// What the config called this entry, for error messages and the --list-plugins report.
    var location: String { name ?? path ?? "" }
}

/// The whole file. Tab order is list order.
struct PluginConfig: Equatable {
    let plugins: [PluginEntry]

    /// The file the app writes when there is none: every built-in, enabled, in the given order.
    static func builtins(named names: [String]) -> PluginConfig {
        PluginConfig(plugins: names.map { PluginEntry(name: $0, path: nil, isEnabled: true) })
    }
}

/// Everything that can go wrong between the file and a `PluginConfig`. Each case says where,
/// as "the top level" or "plugins[3]", because the window shows this text.
enum PluginConfigError: Error, LocalizedError, Equatable, CustomStringConvertible {
    case unreadable(String)
    case unwritable(String)
    case malformedJSON(String)
    case notAnObject(where: String)
    case unknownKey(String, where: String)
    case missingKey(String, where: String)
    case wrongType(key: String, expected: String, where: String)
    case entryNeedsNameOrPath(where: String)
    case entryHasBoth(where: String)

    var description: String {
        switch self {
        case .unreadable(let detail):
            return "could not read plugins.json: \(detail)"
        case .unwritable(let detail):
            return "could not write plugins.json: \(detail)"
        case .malformedJSON(let detail):
            return "plugins.json is not valid JSON: \(detail)"
        case .notAnObject(let place):
            return "\(place) must be an object"
        case let .unknownKey(key, place):
            return "\(place) has an unknown key \"\(key)\""
        case let .missingKey(key, place):
            return "\(place) is missing \"\(key)\""
        case let .wrongType(key, expected, place):
            return "\(place): \"\(key)\" must be \(expected)"
        case .entryNeedsNameOrPath(let place):
            return "\(place) needs a \"name\" or a \"path\""
        case .entryHasBoth(let place):
            return "\(place) has both \"name\" and \"path\"; use one"
        }
    }

    var errorDescription: String? { description }
}

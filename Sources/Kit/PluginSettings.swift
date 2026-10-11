import Foundation

/// The `settings` object from a plugin's entry in plugins.json, as the host hands it to the
/// plugin in `HostServices.settings`. The host checks only that it is an object; the keys and
/// their types are the plugin's to define and to check, so a plugin reports a bad value in its
/// own status line rather than refusing to load. An entry with no `settings` gets `.empty`.
///
/// Tell an absent key from a wrong-typed one with the subscript: `bool(forKey:)` is nil for
/// both, while `settings[key]` is nil only when the key is absent.
public struct PluginSettings: Sendable, Equatable {
    /// One JSON value. Numbers are doubles, as JSON has no integers. The enum is not frozen:
    /// a plugin switching over it needs `@unknown default`.
    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case number(Double)
        case string(String)
        case list([Value])
        case object([String: Value])
        case null
    }

    /// Every key in the object, as written.
    public let values: [String: Value]

    /// No settings at all: what a plugin gets when its entry has no `settings` key.
    public static let empty = PluginSettings(values: [:])

    public init(values: [String: Value]) {
        self.values = values
    }

    /// The raw value under `key`, or nil when the key is absent.
    public subscript(key: String) -> Value? {
        values[key]
    }

    /// The boolean under `key`; nil when the key is absent or holds anything but true or false.
    public func bool(forKey key: String) -> Bool? {
        if case .bool(let flag)? = values[key] { return flag }
        return nil
    }

    /// The number under `key`; nil when the key is absent or holds anything but a number.
    public func number(forKey key: String) -> Double? {
        if case .number(let number)? = values[key] { return number }
        return nil
    }

    /// The string under `key`; nil when the key is absent or holds anything but a string.
    public func string(forKey key: String) -> String? {
        if case .string(let text)? = values[key] { return text }
        return nil
    }
}

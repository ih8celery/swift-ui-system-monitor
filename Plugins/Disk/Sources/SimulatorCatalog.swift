import Foundation

/// What `xcrun simctl list devices -j` says about each device, keyed by udid. Runtimes come as
/// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` and read better as `iOS 26.5`.
enum SimulatorCatalog {
    static let command = "/usr/bin/xcrun"
    static let arguments = ["simctl", "list", "devices", "-j"]
    private static let runtimePrefix = "com.apple.CoreSimulator.SimRuntime."
    private static let dates = ISO8601DateFormatter()

    static func parse(_ output: String) -> [String: SimulatorInfo] {
        guard let data = output.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return [:] }
        var catalog: [String: SimulatorInfo] = [:]
        for (runtime, list) in devices {
            for device in list {
                guard let udid = device["udid"] as? String else { continue }
                catalog[udid] = SimulatorInfo(
                    udid: udid,
                    name: device["name"] as? String ?? udid,
                    runtime: runtimeLabel(runtime),
                    lastBootedAt: (device["lastBootedAt"] as? String).flatMap(dates.date(from:))
                )
            }
        }
        return catalog
    }

    static func runtimeLabel(_ identifier: String) -> String {
        let short = identifier.hasPrefix(runtimePrefix) ? String(identifier.dropFirst(runtimePrefix.count)) : identifier
        let parts = short.split(separator: "-")
        guard parts.count >= 2 else { return short }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }
}

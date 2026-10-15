import Foundation
import SystemBarKit

/// Where every plugin's `HostServices.notify` ends up, so a plugin that misbehaves cannot spam:
/// within one `cooldown` a rule shows once, and a plugin shows at most `ceilingPerPlugin`
/// notifications however many rule ids it makes up. The plugin is the one `HostServices.forPlugin`
/// stamped on the notification, never anything read out of the id. Any thread.
final class NotificationGate: @unchecked Sendable {
    /// One notification per rule per hour.
    static let standardCooldown: TimeInterval = 3600
    /// The most notifications one plugin shows within a cooldown, across all its rules.
    static let ceilingPerPlugin = 5
    /// What a notification with no plugin stamped on it counts against: one from the template
    /// host itself, which no loaded plugin uses.
    static let unstampedPlugin = ""

    private enum Verdict {
        case deliver, repeated, overCeiling, overCeilingFirst
    }

    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let deliver: @Sendable (PluginNotification) -> Void
    private let lock = NSLock()
    /// Plugin, then rule, to when it was last delivered; nothing older than the cooldown.
    private var delivered: [String: [String: Date]] = [:]
    /// Plugins whose ceiling has been logged, and when, so it is logged once per cooldown.
    private var ceilingLogged: [String: Date] = [:]

    init(
        cooldown: TimeInterval = NotificationGate.standardCooldown,
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void,
        deliver: @escaping @Sendable (PluginNotification) -> Void
    ) {
        self.cooldown = cooldown
        self.now = now
        self.log = log
        self.deliver = deliver
    }

    /// How many deliveries the gate remembers, across every plugin. For tests.
    var trackedCount: Int {
        lock.withLock { delivered.values.reduce(0) { $0 + $1.count } }
    }

    func post(_ notification: PluginNotification) {
        let plugin = notification.plugin ?? Self.unstampedPlugin
        switch verdict(plugin: plugin, rule: notification.id) {
        case .deliver:
            deliver(notification)
        case .overCeilingFirst:
            log("Notifications from \(plugin): \(Self.ceilingPerPlugin) shown within the last hour; dropping more, starting with \(notification.id)")
        case .repeated, .overCeiling:
            break
        }
    }

    private func verdict(plugin: String, rule: String) -> Verdict {
        lock.withLock {
            let time = now()
            prune(before: time.addingTimeInterval(-cooldown))
            var rules = delivered[plugin] ?? [:]
            if rules[rule] != nil {
                return .repeated
            }
            if rules.count >= Self.ceilingPerPlugin {
                guard ceilingLogged[plugin] == nil else { return .overCeiling }
                ceilingLogged[plugin] = time
                return .overCeilingFirst
            }
            rules[rule] = time
            delivered[plugin] = rules
            return .deliver
        }
    }

    /// Forgets every delivery and ceiling log at or before `cutoff`. Called with the lock held.
    private func prune(before cutoff: Date) {
        delivered = delivered
            .mapValues { rules in rules.filter { $0.value > cutoff } }
            .filter { !$0.value.isEmpty }
        ceilingLogged = ceilingLogged.filter { $0.value > cutoff }
    }
}

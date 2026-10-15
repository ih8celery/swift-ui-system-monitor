import Foundation
import SystemBarKit

/// Where every plugin's `HostServices.notify` ends up: passes a rule's notification on to
/// `deliver` at most once per `cooldown`, so a rule that stays true, or a plugin that misbehaves,
/// cannot repeat itself. Ids arrive as `<plugin>/<rule>` from `HostServices.forPlugin`, so each
/// plugin's rules are counted apart. Any thread.
final class NotificationGate: @unchecked Sendable {
    /// One notification per rule per hour.
    static let standardCooldown: TimeInterval = 3600

    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private let deliver: @Sendable (PluginNotification) -> Void
    private let lock = NSLock()
    private var lastDelivered: [String: Date] = [:]

    init(
        cooldown: TimeInterval = NotificationGate.standardCooldown,
        now: @escaping @Sendable () -> Date = { Date() },
        deliver: @escaping @Sendable (PluginNotification) -> Void
    ) {
        self.cooldown = cooldown
        self.now = now
        self.deliver = deliver
    }

    func post(_ notification: PluginNotification) {
        let isDue = lock.withLock {
            let time = now()
            if let last = lastDelivered[notification.id], time.timeIntervalSince(last) < cooldown {
                return false
            }
            lastDelivered[notification.id] = time
            return true
        }
        if isDue {
            deliver(notification)
        }
    }
}

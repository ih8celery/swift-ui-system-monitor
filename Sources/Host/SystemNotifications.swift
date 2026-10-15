import Foundation
import SystemBarKit
import UserNotifications

/// Shows a plugin's notification in Notification Center: the app's one real delivery, behind
/// `NotificationGate`. Nothing here runs until a rule fires, so macOS asks for permission the
/// first time one does, never at launch; after the person answers, macOS remembers and asks no
/// more. A test may build one only because the test binary has no bundle, where this skips
/// Notification Center entirely; nothing a test does reaches it.
final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var hasLoggedNoBundle = false

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        super.init()
    }

    /// Becomes the center's delegate, so a notification still shows while the popover is open
    /// and SystemBar is the active app. The center holds its delegate weakly; the caller keeps
    /// this object alive.
    func becomeDelegate() {
        guard isInAppBundle() else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Notification Center raises an exception in a process with no bundle identifier, such as
    /// `build/SystemBar` run straight from the build folder. There, notifications are skipped,
    /// and the log says so once.
    private func isInAppBundle() -> Bool {
        guard Bundle.main.bundleIdentifier == nil else { return true }
        let isFirst = lock.withLock {
            defer { hasLoggedNoBundle = true }
            return !hasLoggedNoBundle
        }
        if isFirst {
            log("Notifications are off: SystemBar is not running from its app bundle")
        }
        return false
    }

    /// Asks for permission (a no-op once the person has answered), then posts. The request is
    /// named `<plugin>/<rule>`, so a newer notification from the same rule replaces the older one
    /// in Notification Center rather than stacking.
    func deliver(_ notification: PluginNotification) {
        guard isInAppBundle() else { return }
        let center = UNUserNotificationCenter.current()
        let log = self.log
        center.requestAuthorization(options: [.alert, .sound]) { isGranted, error in
            if let error {
                log("Notification \(notification.qualifiedID) not shown: \(error.localizedDescription)")
                return
            }
            guard isGranted else {
                log("Notification \(notification.qualifiedID) not shown: notifications are turned off for SystemBar in System Settings")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            let request = UNNotificationRequest(identifier: notification.qualifiedID, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    log("Notification \(notification.qualifiedID) not shown: \(error.localizedDescription)")
                }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

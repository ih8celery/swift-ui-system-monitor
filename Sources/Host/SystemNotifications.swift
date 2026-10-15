import Foundation
import SystemBarKit
import UserNotifications

/// Shows a plugin's notification in Notification Center: the app's one real delivery, behind
/// `NotificationGate`. Nothing here runs until a rule fires, so macOS asks for permission the
/// first time one does, never at launch; after the person answers, macOS remembers and asks no
/// more. Built only by the app, never by a test, because Notification Center refuses a process
/// that is not an app bundle.
final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        super.init()
    }

    /// Becomes the center's delegate, so a notification still shows while the popover is open
    /// and SystemBar is the active app. The center holds its delegate weakly; the caller keeps
    /// this object alive.
    func becomeDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks for permission (a no-op once the person has answered), then posts. The request is
    /// named after the rule, so a newer notification from the same rule replaces the older one
    /// in Notification Center rather than stacking.
    func deliver(_ notification: PluginNotification) {
        let center = UNUserNotificationCenter.current()
        let log = self.log
        center.requestAuthorization(options: [.alert, .sound]) { isGranted, error in
            if let error {
                log("Notification \(notification.id) not shown: \(error.localizedDescription)")
                return
            }
            guard isGranted else {
                log("Notification \(notification.id) not shown: notifications are turned off for SystemBar in System Settings")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    log("Notification \(notification.id) not shown: \(error.localizedDescription)")
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

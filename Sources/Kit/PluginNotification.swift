import Foundation

/// One notification a plugin asked for through `HostServices.notify(id:title:body:)`, as a
/// test sees it in `HostServices.recordingNotifications()`.
public struct PluginNotification: Sendable, Equatable {
    /// The rule that fired, e.g. `low-space`. The host allows one notification per rule per
    /// cooldown, so a rule that stays true keeps one id rather than making a new one each time.
    public let id: String
    /// The notification's bold first line, e.g. `Disk almost full`.
    public let title: String
    /// The line under it, e.g. `12 GB free on Macintosh HD`.
    public let body: String

    /// Builds one by hand, e.g. for a test's expected value.
    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// Every notification passed to it, in order, behind a lock so any thread may post.
final class NotificationRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var posted: [PluginNotification] = []

    func record(_ notification: PluginNotification) {
        lock.withLock { posted.append(notification) }
    }

    var all: [PluginNotification] { lock.withLock { posted } }
}

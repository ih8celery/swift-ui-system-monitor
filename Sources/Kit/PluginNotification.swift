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
    /// The identifier of the plugin that posted it, set by the host for each plugin it loads and
    /// nil from a host a test builds. Package-only, so a plugin can neither set nor forge it.
    package let plugin: String?

    /// Builds one by hand, e.g. for a test's expected value.
    public init(id: String, title: String, body: String) {
        self.init(id: id, title: title, body: body, plugin: nil)
    }

    /// The host's side: one stamped with the plugin that posted it.
    package init(id: String, title: String, body: String, plugin: String?) {
        self.id = id
        self.title = title
        self.body = body
        self.plugin = plugin
    }

    /// `<plugin>/<id>` when the host knows the plugin, the bare id otherwise: unique across
    /// plugins, so the app names each Notification Center request with it. Package-only.
    package var qualifiedID: String {
        plugin.map { "\($0)/\(id)" } ?? id
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

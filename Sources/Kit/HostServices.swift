import Foundation

/// Runs one executable with an argument array and returns what it printed. Never a shell.
public typealias CommandRunner = @Sendable (
    _ path: String, _ arguments: [String], _ environment: [String: String]?, _ timeout: TimeInterval
) -> CommandOutput

/// What the host hands every plugin at construction. A plugin keeps it for its lifetime and may
/// use it from any thread.
public final class HostServices: Sendable {
    /// The signed-in user's home folder as an absolute path with no trailing slash, e.g.
    /// `/Users/ada`. Use it to resolve paths such as `~/proj` without asking the environment.
    public let homeDirectory: String
    /// The 10-second process summary: top by CPU, top by memory, counts. Sampled only while a
    /// visible plugin lists `.processes` in its `sharedFeeds`.
    public let processes: Feed<ProcessSummary>
    /// The 1-second sample: CPU percent and network rates with their short histories. Sampled
    /// whenever the window is open, so listing `.fastStats` only documents the dependency today.
    public let fastStats: Feed<FastStatsSnapshot>
    /// The `settings` object from this plugin's entry in plugins.json, or `.empty`. The keys
    /// are the plugin's own; see `PluginSettings`.
    public let settings: PluginSettings
    /// A folder for this plugin alone, `~/Library/Application Support/SystemBar/PluginData/<id>/`
    /// in the app. It may not exist yet: create it (with intermediate directories) before
    /// writing. A plugin that saves anything between launches saves it here and nowhere else,
    /// so a test can point the whole app at a temporary root with SYSTEMBAR_PLUGIN_DATA_ROOT.
    public let dataDirectory: URL
    private let runner: CommandRunner
    private let logger: @Sendable (String) -> Void
    private let notifier: @Sendable (PluginNotification) -> Void

    /// Anyone may build one; the tests do. By convention only the app does, and the rule that
    /// subprocesses never go through a shell is upheld by the runner's shape: an explicit
    /// executable path and an argument array, nothing to interpolate.
    public init(
        homeDirectory: String,
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        runner: @escaping CommandRunner,
        log: @escaping @Sendable (String) -> Void,
        settings: PluginSettings,
        dataDirectory: URL
    ) {
        self.homeDirectory = homeDirectory
        self.processes = processes
        self.fastStats = fastStats
        self.runner = runner
        self.logger = log
        self.settings = settings
        self.dataDirectory = dataDirectory
        self.notifier = { _ in }
    }

    /// As the initializer above, with somewhere for `notify(id:title:body:)` to go. A plugin's
    /// test passes the `notify` half of `recordingNotifications()`, so nothing reaches
    /// Notification Center; the app passes its own delivery. The initializers without it drop
    /// every notification.
    public init(
        homeDirectory: String,
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        runner: @escaping CommandRunner,
        log: @escaping @Sendable (String) -> Void,
        settings: PluginSettings,
        dataDirectory: URL,
        notify: @escaping @Sendable (PluginNotification) -> Void
    ) {
        self.homeDirectory = homeDirectory
        self.processes = processes
        self.fastStats = fastStats
        self.runner = runner
        self.logger = log
        self.settings = settings
        self.dataDirectory = dataDirectory
        self.notifier = notify
    }

    /// For a plugin's tests, as `Feed.forTesting` is for feeds: pass `notify` to
    /// `init(homeDirectory:processes:fastStats:runner:log:settings:dataDirectory:notify:)`, and
    /// `posted()` returns every notification the plugin asked for, in order, from any thread.
    /// No cooldown applies here, so a test sees exactly what its rule decided.
    public static func recordingNotifications() -> (
        notify: @Sendable (PluginNotification) -> Void,
        posted: @Sendable () -> [PluginNotification]
    ) {
        let recording = NotificationRecording()
        return ({ recording.record($0) }, { recording.all })
    }

    /// The original initializer, kept so plugin tests written against it still compile: empty
    /// settings, and a data folder under the temporary directory that nothing reads back.
    public convenience init(
        homeDirectory: String,
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        runner: @escaping CommandRunner,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            homeDirectory: homeDirectory,
            processes: processes,
            fastStats: fastStats,
            runner: runner,
            log: log,
            settings: .empty,
            dataDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SystemBar-plugin-data-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        )
    }

    /// The host's side: this host's feeds, runner and log, with one plugin's settings and its
    /// own folder under `dataRoot`. Package-only: the catalog builds one per loaded plugin.
    /// The plugin's notifications reach this host's with the id `<identifier>/<rule id>`, so two
    /// plugins' rules never share a cooldown, or are dropped when `notificationsEnabled` is false.
    package func forPlugin(
        identifier: String, settings: PluginSettings, dataRoot: URL, notificationsEnabled: Bool
    ) -> HostServices {
        let notifier = self.notifier
        return HostServices(
            homeDirectory: homeDirectory,
            processes: processes,
            fastStats: fastStats,
            runner: runner,
            log: logger,
            settings: settings,
            dataDirectory: dataRoot.appendingPathComponent(identifier, isDirectory: true),
            notify: { notification in
                guard notificationsEnabled else { return }
                notifier(PluginNotification(
                    id: "\(identifier)/\(notification.id)", title: notification.title, body: notification.body
                ))
            }
        )
    }

    /// The way a plugin runs a subprocess: explicit path, argument array, no shell.
    /// `environment` exists because an app started by launchd has almost no PATH; a plugin that
    /// runs a `#!/usr/bin/env node` script has to say where node is. A non-nil `environment`
    /// replaces the child's inherited environment entirely; it does not merge. To override one
    /// key, start from `ProcessInfo.processInfo.environment` and change that key.
    public func run(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = ProcessRunner.defaultTimeout
    ) -> CommandOutput {
        runner(path, arguments, environment, timeout)
    }

    /// Asks the host to show a notification. `id` names the rule that fired, and is the plugin's
    /// own: the host shows one notification per rule per cooldown (an hour in the app) and
    /// drops repeats inside it, so a rule may call this on every sample while it holds. Nothing
    /// is shown when the user has set `"notifications": false` in plugins.json or refused
    /// permission; macOS asks for that permission the first time any plugin's rule fires. Any
    /// thread; returns at once and does not say whether the notification was shown.
    public func notify(id: String, title: String, body: String) {
        notifier(PluginNotification(id: id, title: title, body: body))
    }

    /// Writes one line to the app's log (the system log, through `NSLog`, in the shipped app).
    /// For things a person debugging a plugin would want to find later, not for every sample.
    public func log(_ message: String) {
        logger(message)
    }
}

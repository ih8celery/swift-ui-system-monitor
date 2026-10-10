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
    private let runner: CommandRunner
    private let logger: @Sendable (String) -> Void

    /// Anyone may build one; the tests do. By convention only the app does, and the rule that
    /// subprocesses never go through a shell is upheld by the runner's shape: an explicit
    /// executable path and an argument array, nothing to interpolate.
    public init(
        homeDirectory: String,
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        runner: @escaping CommandRunner,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.homeDirectory = homeDirectory
        self.processes = processes
        self.fastStats = fastStats
        self.runner = runner
        self.logger = log
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

    /// Writes one line to the app's log (the system log, through `NSLog`, in the shipped app).
    /// For things a person debugging a plugin would want to find later, not for every sample.
    public func log(_ message: String) {
        logger(message)
    }
}

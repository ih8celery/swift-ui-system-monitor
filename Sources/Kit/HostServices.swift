import Foundation

/// Runs one executable with an argument array and returns what it printed. Never a shell.
public typealias CommandRunner = (
    _ path: String, _ arguments: [String], _ environment: [String: String]?, _ timeout: TimeInterval
) -> CommandOutput

/// What the host hands every plugin at construction. A plugin keeps it for its lifetime.
public final class HostServices {
    public let homeDirectory: String
    private let runner: CommandRunner
    private let logger: (String) -> Void

    /// Internal on purpose: only the host constructs one, so a plugin cannot supply its own runner.
    init(homeDirectory: String, runner: @escaping CommandRunner, log: @escaping (String) -> Void) {
        self.homeDirectory = homeDirectory
        self.runner = runner
        self.logger = log
    }

    /// The only way built-in plugins run a subprocess: explicit path, argument array, no shell.
    /// `environment` exists because an app started by launchd has almost no PATH; a plugin that
    /// runs a `#!/usr/bin/env node` script has to say where node is.
    public func run(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = ProcessRunner.defaultTimeout
    ) -> CommandOutput {
        runner(path, arguments, environment, timeout)
    }

    public func log(_ message: String) {
        logger(message)
    }
}

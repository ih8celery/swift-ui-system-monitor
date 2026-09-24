import Foundation

extension UnifiedMonitor {
    /// The collectors still call this. It is a forwarder until each collector moves into its
    /// plugin and calls `HostServices.run` instead; it goes when the last one does.
    static func runProcess(
        path: String,
        arguments: [String],
        timeout: TimeInterval = ProcessRunner.defaultTimeout
    ) -> CommandOutput {
        ProcessRunner.run(path: path, arguments: arguments, timeout: timeout)
    }
}

import AppKit
import Foundation

/// "Edit plugins.json and restart" needs a one-click restart. Under the LaunchAgent that
/// install.sh registers, launchd owns the process and KeepAlive would restart a quit copy
/// anyway, so asking launchd to kick it is the only restart that never leaves two copies
/// running. Anywhere else, start a second copy of this executable and quit.
enum Relauncher {
    static let launchAgentLabel = "com.ih8celery.systembar"

    private static let pidLinePrefix = "pid = "
    private static let launchctlPath = "/bin/launchctl"
    private static let probeTimeout: TimeInterval = 5

    static func launchctlProbeArguments(uid: uid_t, label: String) -> [String] {
        ["print", "gui/\(uid)/\(label)"]
    }

    static func launchctlKickstartArguments(uid: uid_t, label: String) -> [String] {
        ["kickstart", "-k", "gui/\(uid)/\(label)"]
    }

    /// `launchctl print` lists `pid = N` for a running service. Comparing it to our own pid is
    /// what tells a dev build started from a terminal apart from the installed agent, even when
    /// both exist: kicking the agent would restart the wrong one.
    static func pid(fromLaunchctlPrint output: String) -> Int32? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(pidLinePrefix) }
            .flatMap { Int32($0.dropFirst(pidLinePrefix.count)) }
    }

    /// Safe to call from any thread; it hops to the main thread to terminate.
    static func relaunch(log: (String) -> Void) {
        let uid = getuid()
        let probe = ProcessRunner.run(path: launchctlPath, arguments: launchctlProbeArguments(uid: uid, label: launchAgentLabel), timeout: probeTimeout)
        if probe.status == 0, pid(fromLaunchctlPrint: probe.output) == getpid() {
            let kick = ProcessRunner.run(path: launchctlPath, arguments: launchctlKickstartArguments(uid: uid, label: launchAgentLabel), timeout: probeTimeout)
            // launchd kills this process as part of a successful kickstart, so getting here at all means
            // it did not, unless status 0 arrived a moment before launchd's kill lands; only a nonzero
            // status or a timeout is actually a failure worth logging.
            if kick.status != 0 || kick.didTimeout {
                log("relaunch: launchctl kickstart returned without restarting us (status \(kick.status), timed out \(kick.didTimeout)): \(kick.error)")
            }
            return
        }
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == launchAgentLabel {
            log("relaunch: running as the launch agent but launchctl could not confirm it (status \(probe.status), timed out \(probe.didTimeout)); staying up rather than risk two copies")
            return
        }
        guard let executable = Bundle.main.executableURL else {
            log("relaunch: this process has no executable URL; quitting instead")
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            return
        }
        let copy = Process()
        copy.executableURL = executable
        copy.arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try copy.run()
        } catch {
            log("relaunch: could not start a second copy (\(error.localizedDescription)); staying up")
            return
        }
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
}

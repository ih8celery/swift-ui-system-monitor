import AppKit
import Foundation

/// "Edit plugins.json and restart" needs a one-click restart. Under the LaunchAgent that
/// install.sh registers, launchd owns the process and KeepAlive would restart a quit copy
/// anyway, so asking launchd to kick it is the only restart that never leaves two copies
/// running. Anywhere else, start a second copy of this executable and quit.
enum Relauncher {
    static let launchAgentLabel = "com.ih8celery.systembar"

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
            .first { $0.hasPrefix("pid = ") }
            .flatMap { Int32($0.dropFirst("pid = ".count)) }
    }

    static func relaunch(log: (String) -> Void) {
        let uid = getuid()
        let probe = ProcessRunner.run(path: "/bin/launchctl", arguments: launchctlProbeArguments(uid: uid, label: launchAgentLabel), timeout: 5)
        if probe.status == 0, pid(fromLaunchctlPrint: probe.output) == getpid() {
            // launchd kills this process as part of the kickstart, so nothing after this runs.
            _ = ProcessRunner.run(path: "/bin/launchctl", arguments: launchctlKickstartArguments(uid: uid, label: launchAgentLabel), timeout: 5)
            return
        }
        guard let executable = Bundle.main.executableURL else {
            log("relaunch: this process has no executable URL; quitting instead")
            NSApplication.shared.terminate(nil)
            return
        }
        let copy = Process()
        copy.executableURL = executable
        do {
            try copy.run()
        } catch {
            log("relaunch: could not start a second copy (\(error.localizedDescription)); staying up")
            return
        }
        NSApplication.shared.terminate(nil)
    }
}

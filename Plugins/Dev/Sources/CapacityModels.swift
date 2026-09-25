import Foundation

struct DeveloperPort: Identifiable {
    var id: String { "\(process)|\(pid)|\(port)|\(localAddress)" }
    let process: String
    let pid: Int
    let port: String
    let localAddress: String
    /// Filled in once the listening process is traced to a repository. Nil for system daemons and
    /// for processes that exited between the `lsof` and `ps` reads. Attribution builds new ports
    /// rather than mutating parsed ones; this is `var` only so the memberwise init can default it.
    var projectName: String? = nil
}

/// How often the Dev tab samples, and how far apart its two rusage reads sit.
enum DevSampling {
    static let refreshInterval: TimeInterval = 60
    /// How far apart the two rusage reads sit. Per-project CPU and disk figures are deltas, so this
    /// is the interval they are measured over — long enough to be meaningful, short enough that the
    /// plugin's own queue is the only thing waiting on it.
    static let sampleWindow: TimeInterval = 1
}

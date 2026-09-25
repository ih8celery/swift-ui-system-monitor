import Foundation

/// One row of `ps -eo pid,ppid,pcpu,rss,etime,args`. Public because two tabs read the whole
/// process table — CPU to explain a tapped group, Dev to trace work to projects — and two
/// bundles can share code only through the SDK.
public struct PidRecord: Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// Raw ps pcpu: percent of a single core, so a busy multi-threaded process can exceed 100.
    public let cpu: Double
    /// Resident memory in bytes (ps reports KB; the parser multiplies by 1024).
    public let memory: UInt64
    /// ps ELAPSED, e.g. "00:10:00" or "3-04:05:06".
    public let etime: String
    /// Everything in args before the first space. Wrong for an executable whose path contains
    /// a space; read args when that matters.
    public let path: String
    /// The full command line, unparsed.
    public let args: String
    /// The basename of `path`. Inherits the same limit: wrong when the executable's path
    /// contains a space, since `path` is only the text before the first one.
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public init(pid: Int32, ppid: Int32, cpu: Double, memory: UInt64, etime: String, path: String, args: String) {
        self.pid = pid
        self.ppid = ppid
        self.cpu = cpu
        self.memory = memory
        self.etime = etime
        self.path = path
        self.args = args
    }
}

/// Reads the output of `ps -eo pid,ppid,pcpu,rss,etime,args`. The caller runs `ps` itself,
/// through `HostServices.run(path: ProcessTable.executable, arguments: ProcessTable.arguments)`,
/// so the SDK never starts a process a plugin did not ask for.
public enum ProcessTable {
    /// Run by explicit path, never through a shell.
    public static let executable = "/bin/ps"
    /// `parse` depends on exactly this column order; change the two together or not at all.
    public static let arguments = ["-eo", "pid,ppid,pcpu,rss,etime,args"]

    /// A pid -> record map. The five leading fields are space-free; args is the whole trailing
    /// remainder, so name and path come from args rather than a separate, space-prone comm
    /// column. The header line and anything unreadable are skipped.
    public static func parse(_ output: String) -> [Int32: PidRecord] {
        var map: [Int32: PidRecord] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(maxSplits: 5, whereSeparator: \.isWhitespace)
            guard parts.count == 6,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }

            let cpu = Double(parts[2]) ?? 0
            let rssKB = UInt64(parts[3]) ?? 0
            let etime = String(parts[4])
            let args = String(parts[5])
            let path = args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? args

            map[pid] = PidRecord(
                pid: pid,
                ppid: ppid,
                cpu: cpu,
                memory: rssKB * 1024,
                etime: etime,
                path: path,
                args: args
            )
        }

        return map
    }
}

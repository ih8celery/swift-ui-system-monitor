import Foundation

/// One row of `ps -eo pid,ppid,pcpu,rss,etime,args`. Public because two tabs read the whole
/// process table — CPU to explain a tapped group, Dev to trace work to projects — and two
/// bundles can share code only through the SDK.
public struct PidRecord: Sendable {
    /// The process's id.
    public let pid: Int32
    /// The id of the process that started it; 1 (launchd) once its real parent has exited.
    public let ppid: Int32
    /// Raw ps pcpu: percent of a single core, so a busy multi-threaded process can exceed 100.
    public let cpu: Double
    /// Resident memory in bytes (ps reports KB; the parser multiplies by 1024).
    public let memory: UInt64
    /// ps ELAPSED, e.g. "00:10:00" or "3-04:05:06".
    public let etime: String
    /// The executable's path. `ProcessTable.parse` finds it in args by taking the shortest run of
    /// space-separated words that names an existing file, so `/Applications/Google Chrome.app/...`
    /// keeps its spaces. When nothing on disk matches (the executable was deleted, or the command
    /// was started by a relative name such as `python3`) it is the text before the first space.
    public let path: String
    /// The full command line, unparsed.
    public let args: String
    /// The basename of `path`: `Google Chrome` for Chrome's main executable, which is also the
    /// group name the shared process list shows (the basename of ps's comm column). Only as
    /// right as `path`, so see its note for the fallback.
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// Builds a record by hand, e.g. for a test; `ProcessTable.parse` makes the real ones.
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

    /// How many words of args the parser will try as a path. A path of more words than this
    /// (more than 15 spaces) is not worth chasing: the parser falls back to the first word, so a
    /// long command line never costs more than this many file checks.
    package static let maximumPathPrefixes = 16

    /// A pid -> record map, with each executable path checked against the disk. Same as
    /// `parse(_:fileExists:)` with `isExistingRegularFile(atPath:)` as the check.
    public static func parse(_ output: String) -> [Int32: PidRecord] {
        parse(output, fileExists: isExistingRegularFile(atPath:))
    }

    /// A pid -> record map. The five leading fields are space-free; args is the whole trailing
    /// remainder, so name and path come from args rather than a separate, space-prone comm
    /// column. The header line and anything unreadable are skipped.
    ///
    /// Each record's `path` is the shortest run of args' space-separated words that `fileExists`
    /// says is there, so an executable whose path has spaces in it comes back whole. Only an
    /// absolute path (one starting with `/`) is looked up; a relative command keeps its first
    /// word without a check. The ordinary row, whose path has no spaces, costs one check; a row
    /// whose executable is gone costs up to `maximumPathPrefixes` checks and keeps its first word.
    /// A caller, such as a test, can pass a fake `fileExists` to keep the disk out of it.
    public static func parse(_ output: String, fileExists: (String) -> Bool) -> [Int32: PidRecord] {
        let records = output.split(whereSeparator: \.isNewline).compactMap { record(from: $0, fileExists: fileExists) }
        return Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    /// The check `parse(_:)` uses: true only when `path` is a regular file, after following a
    /// symbolic link to whatever it points at. False for a folder, a device such as `/dev/null`,
    /// a socket, a FIFO, a broken link or nothing at all, so `/Applications/Google` never passes
    /// for an executable.
    public static func isExistingRegularFile(atPath path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile ?? false
    }

    /// One row, or nil for the header and anything unreadable.
    private static func record(from line: Substring, fileExists: (String) -> Bool) -> PidRecord? {
        let parts = line.split(maxSplits: 5, whereSeparator: \.isWhitespace)
        guard parts.count == 6,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]) else { return nil }

        let args = String(parts[5])
        return PidRecord(
            pid: pid,
            ppid: ppid,
            cpu: Double(parts[2]) ?? 0,
            memory: (UInt64(parts[3]) ?? 0) * 1024,
            etime: String(parts[4]),
            path: executablePath(in: args, fileExists: fileExists),
            args: args
        )
    }

    /// Tries "first word", then "first two words", and so on up to the cap, and stops at the first
    /// one that exists. Falls back to the first word when none does.
    private static func executablePath(in args: String, fileExists: (String) -> Bool) -> String {
        // At most one more piece than the cap, so the last piece is the untried remainder and a
        // very long command line is never split all the way through.
        let words = args.split(separator: " ", maxSplits: maximumPathPrefixes, omittingEmptySubsequences: false)
        let firstWord = words.first.map(String.init) ?? args
        guard args.hasPrefix("/") else { return firstWord }

        let prefixCount = min(words.count, maximumPathPrefixes)
        let candidates = (1...prefixCount).lazy.map { words.prefix($0).joined(separator: " ") }
        return candidates.first(where: fileExists) ?? firstWord
    }
}

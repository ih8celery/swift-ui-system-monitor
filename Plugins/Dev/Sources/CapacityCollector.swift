import Darwin
import Foundation
import SystemBarKit

enum CapacityCollector {
    /// One tick of the Dev tab: find the expensive work, trace it to projects, and measure what
    /// it is actually drawing. Blocks for `sampleWindow` between its two rusage reads, which is
    /// why it runs on the plugin's own queue and nowhere else.
    static func collect(using host: HostServices, sampleWindow: TimeInterval = DevSampling.sampleWindow) -> CapacitySnapshot {
        let table = host.run(path: ProcessTable.executable, arguments: ProcessTable.arguments)
        let listen = host.run(path: "/usr/sbin/lsof", arguments: ["-n", "-P", "-iTCP", "-sTCP:LISTEN"])
        let therm = host.run(path: "/usr/bin/pmset", arguments: ["-g", "therm"])

        // Failures decide health and colour the status line as trouble. Notes are things worth
        // saying that are not wrong with the sample — a process ending mid-read is routine.
        var failures: [String] = []
        var notes: [String] = []
        if table.status != 0 { failures.append("process table unavailable") }
        if listen.status != 0 { failures.append("lsof listen unavailable") }
        if therm.status != 0 { failures.append("thermal warnings unavailable") }

        let records = table.status == 0 ? ProcessTable.parse(table.output) : [:]
        let ports = listen.status == 0 ? Self.parseListeningPorts(listen.output) : []
        let warnings = therm.status == 0
            ? Self.parseThermalWarnings(therm.output)
            : (hasThermalWarning: false, hasPerformanceWarning: false)

        let resolver = ProjectResolver(homeDirectory: host.homeDirectory)
        let work = Self.categorizedProcesses(in: records, resolver: resolver)
        let attributedPorts = Self.attributedPorts(Array(ports.prefix(24)), records: records, resolver: resolver)

        // Two reads a known interval apart: the figures are deltas, so a single read could only
        // produce lifetime averages, which is exactly the kind of number this panel must not show.
        let pids = work.map(\.pid)
        let before = Self.rusageSamples(for: pids)
        let startedAt = Date()
        Thread.sleep(forTimeInterval: sampleWindow)
        let after = Self.rusageSamples(for: pids)
        let elapsed = Date().timeIntervalSince(startedAt)

        // Busyness is decided from the measurement, not before it: every categorized process is
        // sampled, then the ones that consumed no CPU over the interval drop out. That also keeps
        // idle simulator daemons from inflating the heat-heavy count behind the capacity grade.
        let measured = ProjectLoadRollup.evidence(
            processes: work,
            first: before,
            second: after,
            elapsed: elapsed
        )

        // Second attribution pass, over only the work believed to be running. A build's arguments
        // carry relative paths and name nothing, but its working directory is the repository — so
        // this is what turns anonymous load into a named row. Idle processes never get here, which
        // is what keeps the ask to a handful of pids.
        let unnamed = Self.workingDirectoryLookupPIDs(for: measured.allWorking)
        let skipped = measured.allWorking.filter { $0.project == nil }.count - unnamed.count
        if skipped > 0 {
            notes.append("\(skipped) more could not be traced to a project this tick")
        }
        let directories = Self.workingDirectories(for: unnamed, using: host)
        let evidence = measured.reattributed {
            Self.attributed($0, workingDirectories: directories, resolver: resolver)
        }

        if evidence.unnamedUnmeasuredCount > 0 {
            let count = evidence.unnamedUnmeasuredCount
            notes.append("\(count) unnamed process\(count == 1 ? "" : "es") could not be measured")
        }
        let rows = ProjectLoadRollup.rows(
            processes: evidence.ledgerProcesses,
            first: before,
            second: after,
            elapsed: elapsed,
            coreCount: ProcessInfo.processInfo.activeProcessorCount
        )
        let thermalState = ProcessInfo.processInfo.thermalState
        let cpuBusy = host.fastStats.value.cpuUsagePercent

        return CapacitySnapshot(
            assessment: CapacityGrade.assess(CapacityInputs(
                cpuBusyPercent: cpuBusy,
                heatHeavyCount: evidence.heatHeavyCount,
                thermalState: thermalState,
                hasThermalWarning: warnings.hasThermalWarning,
                hasPerformanceWarning: warnings.hasPerformanceWarning,
                cpuTemperatureCelsius: nil
            )),
            rows: rows,
            ports: attributedPorts,
            cpuBusyPercent: cpuBusy,
            thermalState: thermalStateLabel(thermalState),
            status: Self.statusText(failures: failures, notes: notes),
            health: SampleHealth(isOK: failures.isEmpty),
            lastUpdated: Date()
        )
    }

    /// Failures come first because they are what a reader must act on; notes follow as context.
    static func statusText(failures: [String], notes: [String]) -> String {
        let parts = failures.isEmpty ? ["Capacity sample OK"] + notes : failures + notes
        return parts.joined(separator: ", ")
    }

    /// Every live process that matches a work category, paired with the project it could be traced
    /// to. Processes matching nothing are ordinary machine activity and are left out entirely.
    static func categorizedProcesses(
        in records: [Int32: PidRecord],
        resolver: ProjectResolver
    ) -> [CategorizedProcess] {
        records.values.compactMap { record in
            guard let category = WorkCategory.classify(path: record.path, args: record.args) else {
                return nil
            }
            return CategorizedProcess(
                pid: record.pid,
                project: resolver.project(forArgs: record.args),
                category: category
            )
        }
    }

    /// Names the project behind each listening port where the port's process can be traced. Ports
    /// that cannot be placed are kept, not dropped — an unexplained port is still worth seeing.
    static func attributedPorts(
        _ ports: [DeveloperPort],
        records: [Int32: PidRecord],
        resolver: ProjectResolver
    ) -> [DeveloperPort] {
        ports.map { port in
            let project = records[Int32(port.pid)].flatMap { resolver.project(forArgs: $0.args) }
            return DeveloperPort(
                process: port.process,
                pid: port.pid,
                port: port.port,
                localAddress: port.localAddress,
                projectName: project?.displayName
            )
        }
    }

    /// Ceiling on how many processes one tick will ask `lsof` about. Generous, because the ask is a
    /// single subprocess covering every pid at once, but bounded so a pathological tick cannot build
    /// an unbounded argument list.
    static let maximumWorkingDirectoryLookups = 64

    /// Which processes still need a working directory: the ones their arguments could not name.
    static func workingDirectoryLookupPIDs(
        for processes: [CategorizedProcess],
        limit: Int = maximumWorkingDirectoryLookups
    ) -> [Int32] {
        processes
            .filter { $0.project == nil }
            .prefix(limit)
            .map(\.pid)
    }

    /// One `lsof` call for every pid at once. Real Swift builds pass relative source paths, so their
    /// arguments name no project — but the build's working directory is the repository itself, which
    /// is the only way a build becomes a named row rather than anonymous load.
    static func workingDirectories(for pids: [Int32], using host: HostServices) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }

        let result = host.run(
            path: "/usr/sbin/lsof",
            arguments: ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")]
        )
        // lsof reports a non-zero status when it could not read some of the pids it was given, and
        // still prints the ones it could, so the output is worth parsing either way.
        return parseWorkingDirectories(result.output)
    }

    /// `lsof -Fpn` field output: a `p<pid>` line opens a process, and a later `n<path>` line gives
    /// that process's working directory. A process with no readable path contributes nothing.
    static func parseWorkingDirectories(_ output: String) -> [Int32: String] {
        var directories: [Int32: String] = [:]
        var currentPID: Int32?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst())
                continue
            }
            guard line.hasPrefix("n"), let pid = currentPID else { continue }
            let path = String(line.dropFirst())
            if !path.isEmpty { directories[pid] = path }
        }

        return directories
    }

    /// Fills in a project for work its arguments could not name, from the directory it runs in. Work
    /// already named from its arguments keeps that answer — the arguments named a path the process
    /// is actually operating on, which is a stronger signal than where it happens to have been
    /// launched from.
    static func attributed(
        _ processes: [CategorizedProcess],
        workingDirectories: [Int32: String],
        resolver: ProjectResolver
    ) -> [CategorizedProcess] {
        processes.map { process in
            guard process.project == nil,
                  let directory = workingDirectories[process.pid],
                  let root = resolver.repositoryRoot(forPath: directory) else {
                return process
            }
            return CategorizedProcess(
                pid: process.pid,
                project: ProjectIdentity(rootPath: root),
                category: process.category
            )
        }
    }

    /// Ported from parseThermal in ShotStep's machine-capacity.js. `pmset -g therm` reports the
    /// absence of a warning in words, so the negated forms must not read as warnings.
    static func parseThermalWarnings(_ output: String) -> (hasThermalWarning: Bool, hasPerformanceWarning: Bool) {
        let lower = output.lowercased()
        return (
            hasThermalWarning: lower.contains("thermal warning") && !lower.contains("no thermal warning"),
            hasPerformanceWarning: lower.contains("performance warning") && !lower.contains("no performance warning")
        )
    }

    /// One `proc_pid_rusage` read per pid. Only categorized processes are ever asked, which is what
    /// bounds the syscall count even while a large build is running.
    static func rusageSamples(for pids: [Int32]) -> [Int32: RusageSample] {
        var samples: [Int32: RusageSample] = [:]
        for pid in pids {
            if let sample = rusageSample(for: pid) {
                samples[pid] = sample
            }
        }
        return samples
    }

    private static func rusageSample(for pid: Int32) -> RusageSample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPointer)
            }
        }
        guard result == 0 else { return nil }

        return RusageSample(
            pid: pid,
            // ri_user_time and ri_system_time are nanoseconds of CPU actually consumed.
            cpuTimeSeconds: Double(info.ri_user_time &+ info.ri_system_time) / 1_000_000_000,
            physicalFootprint: info.ri_phys_footprint,
            diskBytesRead: info.ri_diskio_bytesread,
            diskBytesWritten: info.ri_diskio_byteswritten
        )
    }

    static func parseListeningPorts(_ output: String) -> [DeveloperPort] {
        var ports: [DeveloperPort] = []
        var seen = Set<String>()

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard !line.hasPrefix("COMMAND"),
                  let tcpRange = line.range(of: " TCP "),
                  line.contains("(LISTEN)") else { continue }

            let fields = line[..<tcpRange.lowerBound].split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  let pid = Int(fields[1]) else { continue }

            let descriptor = line[tcpRange.upperBound...]
                .replacingOccurrences(of: "(LISTEN)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = port(from: descriptor) else { continue }
            let process = String(fields[0]).replacingOccurrences(of: "\\x20", with: " ")
            let key = "\(process)|\(pid)|\(port)|\(descriptor)"
            guard seen.insert(key).inserted else { continue }

            ports.append(DeveloperPort(
                process: process,
                pid: pid,
                port: port,
                localAddress: descriptor
            ))
        }

        return ports.sorted {
            if $0.port == $1.port {
                return $0.process.localizedCaseInsensitiveCompare($1.process) == .orderedAscending
            }
            return (Int($0.port) ?? Int.max) < (Int($1.port) ?? Int.max)
        }
    }

    /// The port after the last colon of an lsof endpoint. The Network bundle has the same helper;
    /// two bundles cannot share code outside the SDK, and six lines do not earn an SDK entry.
    static func port(from endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: ":") else { return nil }
        let port = trimmed[trimmed.index(after: separator)...]
        return port.isEmpty ? nil : String(port)
    }
}

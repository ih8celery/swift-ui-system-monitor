import Darwin
import Foundation

extension UnifiedMonitor {
    /// One tick of the Dev tab's sampler: find the expensive work, trace it to projects, and measure
    /// what it is actually drawing. Runs on the developer queue, which is also the only thing that
    /// waits out the sample window.
    func collectCapacity() {
        guard !isCollectingCapacity else { return }
        isCollectingCapacity = true
        defer { isCollectingCapacity = false }

        let table = Self.runProcess(path: "/bin/ps", arguments: ["-eo", "pid,ppid,pcpu,rss,etime,args"])
        let listen = Self.runProcess(path: "/usr/sbin/lsof", arguments: ["-n", "-P", "-iTCP", "-sTCP:LISTEN"])
        let therm = Self.runProcess(path: "/usr/bin/pmset", arguments: ["-g", "therm"])

        // Failures decide health and colour the status line as trouble. Notes are things worth
        // saying that are not wrong with the sample — a process ending mid-read is routine.
        var failures: [String] = []
        var notes: [String] = []
        if table.status != 0 { failures.append("process table unavailable") }
        if listen.status != 0 { failures.append("lsof listen unavailable") }
        if therm.status != 0 { failures.append("thermal warnings unavailable") }

        let records = table.status == 0 ? Self.parseProcessTable(table.output) : [:]
        let ports = listen.status == 0 ? Self.parseListeningPorts(listen.output) : []
        let warnings = therm.status == 0
            ? Self.parseThermalWarnings(therm.output)
            : (hasThermalWarning: false, hasPerformanceWarning: false)

        let resolver = ProjectResolver()
        let work = Self.categorizedProcesses(in: records, resolver: resolver)
        let attributedPorts = Self.attributedPorts(Array(ports.prefix(24)), records: records, resolver: resolver)

        // Two reads a known interval apart: the figures are deltas, so a single read could only
        // produce lifetime averages, which is exactly the kind of number this panel must not show.
        let pids = work.map(\.pid)
        let before = Self.rusageSamples(for: pids)
        let startedAt = Date()
        Thread.sleep(forTimeInterval: MonitorSamplingPlan.capacitySampleWindow)
        let after = Self.rusageSamples(for: pids)
        let elapsed = Date().timeIntervalSince(startedAt)

        // Busyness is decided from the measurement, not before it: every categorized process is
        // sampled, then the ones that consumed no CPU over the interval drop out. That also keeps
        // idle simulator daemons from inflating the heat-heavy count behind the capacity grade.
        let evidence = ProjectLoadRollup.evidence(
            processes: work,
            first: before,
            second: after,
            elapsed: elapsed
        )
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
        let sampleDate = Date()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // cpuUsagePercent is owned by the main-thread snapshot, so the grade is assembled here
            // rather than read across queues.
            let cpuBusy = self.fastStats.cpuUsagePercent
            self.capacitySnapshot = CapacitySnapshot(
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
                thermalState: Self.thermalStateLabel(thermalState),
                status: Self.statusText(failures: failures, notes: notes),
                health: SampleHealth(isOK: failures.isEmpty),
                lastUpdated: sampleDate
            )
        }
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

    static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
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
}

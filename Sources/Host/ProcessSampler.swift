import Foundation
import SystemBarKit

/// The 10-second process summary behind `HostServices.processes`: one `ps` of every process,
/// grouped by name, with the exact memory footprint read only for the groups that will be shown.
enum ProcessSampler {
    /// Below a megabyte resident, a process is noise in a top-N list.
    static let minimumResidentBytes: UInt64 = 1_048_576

    static func summary(
        runner: CommandRunner,
        footprint: (Int32) -> UInt64? = ProcessTable.physicalFootprint(pid:)
    ) -> ProcessSummary {
        ProcessSummary(rows: snapshots(samples: runPS(runner: runner), footprint: footprint))
    }

    /// Groups ps rows by name. `footprint` is `ProcessTable.physicalFootprint` in the app and a fake in tests.
    static func snapshots(
        samples allSamples: [RawProcessSample],
        memoryLimit: Int = ProcessSummary.memoryDisplayLimit,
        cpuLimit: Int = ProcessSummary.cpuDisplayLimit,
        footprint: (Int32) -> UInt64?
    ) -> [ProcessSnapshot] {
        let samples = allSamples.filter { $0.rss >= minimumResidentBytes }
        guard !samples.isEmpty else { return [] }

        // proc_pid_rusage is hundreds of syscalls per 10s cycle if called for
        // every process; only the groups that would actually be displayed are
        // worth refining, so pick those using ps's cheap rss/pcpu first.
        let refinedNames = groupsNeedingRefinement(
            samples: samples.map { (name: $0.name, rss: $0.rss, cpu: $0.cpu) },
            memoryLimit: memoryLimit,
            cpuLimit: cpuLimit
        )

        var groups: [String: (count: Int, physical: UInt64, virtualSize: UInt64, cpu: Double)] = [:]
        for sample in samples {
            let physical = refinedNames.contains(sample.name)
                ? (footprint(sample.pid) ?? sample.rss)
                : sample.rss

            var group = groups[sample.name] ?? (count: 0, physical: 0, virtualSize: 0, cpu: 0)
            group.count += 1
            group.physical += physical
            group.virtualSize += sample.virtualSize
            group.cpu += sample.cpu
            groups[sample.name] = group
        }

        return groups.map { name, group in
            ProcessSnapshot(
                name: name,
                count: group.count,
                physical: group.physical,
                virtualSize: group.virtualSize,
                cpu: group.cpu
            )
        }
    }

    /// Group names whose *grouped* memory or CPU total (summed from cheap `ps`
    /// data) would land in the displayed top-N. Pure and syscall-free so the
    /// selection is testable without spawning processes.
    static func groupsNeedingRefinement(
        samples: [(name: String, rss: UInt64, cpu: Double)],
        memoryLimit: Int,
        cpuLimit: Int
    ) -> Set<String> {
        var totals: [String: (physical: UInt64, cpu: Double)] = [:]
        for sample in samples {
            var total = totals[sample.name] ?? (physical: 0, cpu: 0)
            total.physical += sample.rss
            total.cpu += sample.cpu
            totals[sample.name] = total
        }

        let byMemory = totals.keys.sorted { totals[$0]!.physical > totals[$1]!.physical }.prefix(memoryLimit)
        let byCPU = totals.keys.sorted { totals[$0]!.cpu > totals[$1]!.cpu }.prefix(cpuLimit)
        return Set(byMemory).union(byCPU)
    }

    static func runPS(runner: CommandRunner) -> [RawProcessSample] {
        let result = runner("/bin/ps", ["-eo", "pid,rss,vsz,pcpu,comm", "-r"], nil, ProcessRunner.defaultTimeout)
        guard result.status == 0 else { return [] }
        return parsePS(result.output)
    }

    /// `ps -eo pid,rss,vsz,pcpu,comm -r` rows; the header and anything unreadable are skipped.
    static func parsePS(_ output: String) -> [RawProcessSample] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let parts = rawLine.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard parts.count == 5, parts[0] != "PID" else { return nil }
            guard let pid = Int32(parts[0]),
                  let rssKB = UInt64(parts[1]),
                  let vszKB = UInt64(parts[2]) else {
                return nil
            }

            let cpu = Double(parts[3]) ?? 0
            let command = String(parts[4])
            let name = URL(fileURLWithPath: command).lastPathComponent
            return RawProcessSample(
                pid: pid,
                rss: rssKB * 1024,
                virtualSize: vszKB * 1024,
                cpu: cpu,
                name: name.isEmpty ? command : name
            )
        }
    }
}

struct RawProcessSample {
    let pid: Int32
    let rss: UInt64
    let virtualSize: UInt64
    let cpu: Double
    let name: String
}

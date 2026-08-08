import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    func collectProcesses() {
        guard !isCollectingProcesses else { return }
        isCollectingProcesses = true
        defer { isCollectingProcesses = false }

        let rows = Self.collectProcessSnapshots()
        let summary = ProcessSummary(rows: rows)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.processSummary = summary
        }
    }


    private static func collectProcessSnapshots(
        memoryLimit: Int = processMemoryDisplayLimit,
        cpuLimit: Int = processCPUDisplayLimit
    ) -> [ProcessSnapshot] {
        let samples = runPS().filter { $0.rss >= 1_048_576 }
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
                ? (physicalFootprint(pid: sample.pid) ?? sample.rss)
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

    // MARK: - On-demand process drill-in (runs only when a row is tapped)

    /// Parse `ps -eo pid,ppid,pcpu,rss,etime,args` output into a pid -> record map.
    /// The five leading fields are space-free; args is the whole trailing remainder,
    /// so name/path derive from args rather than a separate (space-prone) comm column.
    static func parseProcessTable(_ output: String) -> [Int32: PidRecord] {
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

    /// Walk up the ppid chain, returning up to `hops` ancestor names. Stops early
    /// when an ancestor is not in the map (e.g. the kernel/pid 0), so chains shorter
    /// than `hops` are handled without inventing names.
    static func parentChain(of pid: Int32, in map: [Int32: PidRecord], hops: Int) -> [String] {
        var names: [String] = []
        var current = map[pid]?.ppid
        var remaining = hops

        while remaining > 0, let ppid = current, let ancestor = map[ppid] {
            names.append(ancestor.name)
            current = ancestor.ppid
            remaining -= 1
        }

        return names
    }

    /// Build per-PID detail rows for every process in the named group.
    static func groupDetail(name: String, in map: [Int32: PidRecord], coreCount: Int) -> [ProcessDetail] {
        map.values
            .filter { $0.name == name }
            .map { record in
                let chain = parentChain(of: record.pid, in: map, hops: 2)
                return ProcessDetail(
                    pid: record.pid,
                    command: record.args,
                    path: record.path,
                    name: record.name,
                    parentName: chain.first ?? "unknown",
                    grandparentName: chain.count > 1 ? chain[1] : "",
                    cpuPercent: ProcessCPUScale.wholeMachinePercent(summedPcpu: record.cpu, coreCount: coreCount),
                    memory: record.memory,
                    uptime: record.etime
                )
            }
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Run the on-demand `ps` snapshot and return the tapped group's detail rows.
    /// Called on tap only — no cost to the idle sampling loop.
    static func fetchGroupDetail(name: String) -> [ProcessDetail] {
        let result = runProcess(path: "/bin/ps", arguments: ["-eo", "pid,ppid,pcpu,rss,etime,args"])
        guard result.status == 0 else { return [] }
        let map = parseProcessTable(result.output)
        return groupDetail(name: name, in: map, coreCount: ProcessInfo.processInfo.activeProcessorCount)
    }


    private static func runPS() -> [RawProcessSample] {
        let result = runProcess(path: "/bin/ps", arguments: ["-eo", "pid,rss,vsz,pcpu,comm", "-r"])
        guard result.status == 0 else { return [] }

        return result.output.split(whereSeparator: \.isNewline).compactMap { rawLine in
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

    private static func physicalFootprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPointer)
            }
        }

        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }


}

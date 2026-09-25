import AppKit
import Darwin
import Foundation
import SwiftUI
import SystemBarKit

extension UnifiedMonitor {
    // MARK: - On-demand process drill-in (runs only when a row is tapped)

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
        let map = ProcessTable.parse(result.output)
        return groupDetail(name: name, in: map, coreCount: ProcessInfo.processInfo.activeProcessorCount)
    }
}

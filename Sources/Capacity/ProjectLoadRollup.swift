import Foundation

/// One `proc_pid_rusage` reading for one process. Everything here is per-PID, which is exactly why
/// it can be attributed to a project without guessing.
struct RusageSample {
    let pid: Int32
    let cpuTimeSeconds: Double
    let physicalFootprint: UInt64
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
}

/// A live process that matched a work category, with the project it was traced to (or none).
struct CategorizedProcess {
    let pid: Int32
    let project: ProjectIdentity?
    let category: WorkCategory
}

struct CategoryCount: Equatable {
    let category: WorkCategory
    let count: Int
}

/// A displayed number is a claim, so there are exactly two states and no third: either the sample
/// completed and the figures are real, or it did not and the row says so. Never a zero standing in
/// for a failure, never a stale value from a previous tick.
enum ProjectLoad {
    case measured(
        cpuPercent: Double,
        memory: UInt64,
        diskReadRate: Double,
        diskWriteRate: Double,
        sampledProcesses: Int,
        totalProcesses: Int
    )
    case unavailable
}

struct ProjectWorkRow: Identifiable {
    /// Nil means the work is real but could not be traced to a repository.
    let project: ProjectIdentity?
    let categories: [CategoryCount]
    let load: ProjectLoad

    var id: String { project?.rootPath ?? "unattributed" }
    var displayName: String { project?.displayName ?? "Unattributed" }
}

/// Turns two rusage samples taken a known interval apart into one row per project.
enum ProjectLoadRollup {
    static func rows(
        processes: [CategorizedProcess],
        first: [Int32: RusageSample],
        second: [Int32: RusageSample],
        elapsed: TimeInterval,
        coreCount: Int
    ) -> [ProjectWorkRow] {
        let grouped = Dictionary(grouping: processes, by: \.project)

        let rows = grouped.map { project, group in
            ProjectWorkRow(
                project: project,
                categories: categoryCounts(in: group),
                load: load(for: group, first: first, second: second, elapsed: elapsed, coreCount: coreCount)
            )
        }

        // Unattributed work sorts last however heavy it is: it is a gap in what we can see, not a
        // project competing for the top of the list.
        let attributed = rows.filter { $0.project != nil }.sorted { sortWeight(of: $0) > sortWeight(of: $1) }
        return attributed + rows.filter { $0.project == nil }
    }

    private static func categoryCounts(in group: [CategorizedProcess]) -> [CategoryCount] {
        WorkCategory.allCases.compactMap { category in
            let count = group.filter { $0.category == category }.count
            return count > 0 ? CategoryCount(category: category, count: count) : nil
        }
    }

    private static func load(
        for group: [CategorizedProcess],
        first: [Int32: RusageSample],
        second: [Int32: RusageSample],
        elapsed: TimeInterval,
        coreCount: Int
    ) -> ProjectLoad {
        guard elapsed > 0 else { return .unavailable }

        var cpuSeconds: Double = 0
        var memory: UInt64 = 0
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var sampled = 0

        for process in group {
            guard let before = first[process.pid], let after = second[process.pid] else { continue }
            // These counters only ever climb for a given process, so a decrease means the pid was
            // recycled between samples and the two readings describe different programs.
            guard after.cpuTimeSeconds >= before.cpuTimeSeconds,
                  after.diskBytesRead >= before.diskBytesRead,
                  after.diskBytesWritten >= before.diskBytesWritten else { continue }

            cpuSeconds += after.cpuTimeSeconds - before.cpuTimeSeconds
            memory &+= after.physicalFootprint
            bytesRead &+= after.diskBytesRead - before.diskBytesRead
            bytesWritten &+= after.diskBytesWritten - before.diskBytesWritten
            sampled += 1
        }

        guard sampled > 0 else { return .unavailable }

        return .measured(
            // cpuSeconds/elapsed is how many cores' worth of work this was; ×100 restates it in
            // ps's percent-of-one-core units so the existing whole-machine scaling applies.
            cpuPercent: ProcessCPUScale.wholeMachinePercent(
                summedPcpu: cpuSeconds / elapsed * 100,
                coreCount: coreCount
            ),
            memory: memory,
            diskReadRate: Double(bytesRead) / elapsed,
            diskWriteRate: Double(bytesWritten) / elapsed,
            sampledProcesses: sampled,
            totalProcesses: group.count
        )
    }

    /// Unmeasured rows sort below every measured one rather than being treated as idle.
    private static func sortWeight(of row: ProjectWorkRow) -> Double {
        if case .measured(let cpuPercent, _, _, _, _, _) = row.load { return cpuPercent }
        return -1
    }
}

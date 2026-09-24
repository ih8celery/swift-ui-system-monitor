import Foundation
import SystemBarKit

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

/// What two rusage reads established about the expensive work on the machine.
///
/// The split matters because Xcode compile jobs cannot be measured at all: `swift-frontend` PIDs are
/// replaced entirely between one second and the next, and a reaped process's CPU time is gone with
/// it. That work is real and heat-heavy even though no number can be attached to it, so it counts
/// toward the machine's grade and shows as a named row without figures — it just never appears as a
/// fabricated zero.
struct WorkEvidence {
    /// Measured, and consuming enough CPU to be worth showing.
    let busy: [CategorizedProcess]
    /// Could not be sampled twice: ended mid-read, or rusage refused.
    let unmeasured: [CategorizedProcess]

    /// Everything believed to be working, measurable or not. This is what the capacity grade counts,
    /// so a running build raises machine stress even though its CPU share is unknowable.
    var heatHeavyCount: Int { busy.count + unmeasured.count }

    /// Unmeasured work with no project would produce a row asserting that something expensive is
    /// happening while carrying no evidence of it, so only named work earns a row.
    var ledgerProcesses: [CategorizedProcess] {
        busy + unmeasured.filter { $0.project != nil }
    }

    /// Counted so the status line can admit what was left out.
    var unnamedUnmeasuredCount: Int {
        unmeasured.filter { $0.project == nil }.count
    }

    /// Everything believed to be working, whether or not it could be measured. This is what a second
    /// attribution pass should be offered, since naming unmeasurable work is what turns a dropped
    /// process into a visible row.
    var allWorking: [CategorizedProcess] { busy + unmeasured }

    /// Runs a second attribution pass over all working processes and returns a new evidence value
    /// with the busy and unmeasured split intact.
    func reattributed(_ resolve: ([CategorizedProcess]) -> [CategorizedProcess]) -> WorkEvidence {
        let updated = Dictionary(
            resolve(allWorking).map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return WorkEvidence(
            busy: busy.map { updated[$0.pid] ?? $0 },
            unmeasured: unmeasured.map { updated[$0.pid] ?? $0 }
        )
    }
}

/// Turns two rusage samples taken a known interval apart into one row per project.
enum ProjectLoadRollup {
    /// How much CPU a process must actually have consumed over the interval to count as expensive
    /// work: one hundredth of a core, the measured equivalent of the capacity script's 1% gate.
    static let minimumBusyCoreShare: Double = 0.01

    /// Which categorized processes are genuinely working right now.
    ///
    /// This cannot use `ps` pcpu the way the capacity script does. pcpu is an average over a
    /// process's whole life, so a compile job spawned two seconds ago reads near zero while burning
    /// a full core — exactly the work this panel exists to show. A measured delta has no such blind
    /// spot.
    ///
    /// What the two reads managed to establish about each categorized process.
    static func evidence(
        processes: [CategorizedProcess],
        first: [Int32: RusageSample],
        second: [Int32: RusageSample],
        elapsed: TimeInterval
    ) -> WorkEvidence {
        guard elapsed > 0 else { return WorkEvidence(busy: [], unmeasured: processes) }

        var busy: [CategorizedProcess] = []
        var unmeasured: [CategorizedProcess] = []

        for process in processes {
            // Some work cannot be measured however cleanly it samples: see WorkCategory.isMeasurable.
            // It counts by being there, and never by the driver's own idle CPU.
            guard process.category.isMeasurable else {
                unmeasured.append(process)
                continue
            }
            guard let before = first[process.pid],
                  let after = second[process.pid],
                  after.cpuTimeSeconds >= before.cpuTimeSeconds else {
                unmeasured.append(process)
                continue
            }
            if (after.cpuTimeSeconds - before.cpuTimeSeconds) / elapsed >= minimumBusyCoreShare {
                busy.append(process)
            }
            // Measured and idle: real evidence that it is costing nothing, so it is simply out.
        }

        return WorkEvidence(busy: busy, unmeasured: unmeasured)
    }

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
            // Unmeasurable categories are counted in totalProcesses but contribute no figures, so a
            // project running a build alongside a bundler shows the bundler's real numbers and says
            // how much of itself that covers.
            guard process.category.isMeasurable else { continue }
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

import Foundation
import SystemBarKit

/// The two samplers the host runs on every plugin's behalf, and when each one runs.
///
/// The 1-second sampler runs whenever the window is open, whatever the tab: the CPU and network
/// histories are ninety seconds long, and stopping it on a tab switch would leave a gap in them.
/// The 10-second process sampler runs only while the visible tab lists `.processes`, because a
/// `ps` of every process is the heavy one. With the window closed, neither runs.
///
/// Main thread only. Each sampler has its own serial queue, so a slow `ps` (it can take up to
/// its 15-second timeout) cannot stall the 1-second ticks and leave a gap in their history.
/// Each sampler's own state is only ever touched from its own queue.
@MainActor
final class HostSamplers {
    nonisolated static let fastInterval: TimeInterval = 1
    nonisolated static let processInterval: TimeInterval = 10

    private let processes: Feed<ProcessSummary>
    private let fastStats: Feed<FastStatsSnapshot>
    private let sampleFast: @Sendable () -> FastStatsSnapshot
    private let sampleProcesses: @Sendable () -> ProcessSummary
    private let fastInterval: TimeInterval
    private let processInterval: TimeInterval
    private let fastQueue = DispatchQueue(label: "systembar.host.fast", qos: .utility)
    private let processQueue = DispatchQueue(label: "systembar.host.processes", qos: .utility)
    private var fastTimer: DispatchSourceTimer?
    private var processTimer: DispatchSourceTimer?

    /// The collectors and intervals are parameters so a test can count calls on a short
    /// interval; the app uses `standard(processes:fastStats:)`.
    init(
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        sampleFast: @escaping @Sendable () -> FastStatsSnapshot,
        sampleProcesses: @escaping @Sendable () -> ProcessSummary,
        fastInterval: TimeInterval = HostSamplers.fastInterval,
        processInterval: TimeInterval = HostSamplers.processInterval
    ) {
        self.processes = processes
        self.fastStats = fastStats
        self.sampleFast = sampleFast
        self.sampleProcesses = sampleProcesses
        self.fastInterval = fastInterval
        self.processInterval = processInterval
    }

    /// The real samplers: the kernel's counters every second, and `ps` through the real runner.
    static func standard(processes: Feed<ProcessSummary>, fastStats: Feed<FastStatsSnapshot>) -> HostSamplers {
        let fast = FastStatsSampler()
        return HostSamplers(
            processes: processes,
            fastStats: fastStats,
            sampleFast: { fast.sample() },
            sampleProcesses: { ProcessSampler.summary(runner: ProcessRunner.run) }
        )
    }

    /// Which samplers a tab that declares `feeds` needs.
    nonisolated static func wanted(isVisible: Bool, feeds: Set<SharedFeed>) -> Set<SharedFeed> {
        guard isVisible else { return [] }
        return feeds.contains(.processes) ? [.fastStats, .processes] : [.fastStats]
    }

    /// Which samplers are running now.
    var running: Set<SharedFeed> {
        Set([fastTimer.map { _ in SharedFeed.fastStats }, processTimer.map { _ in SharedFeed.processes }].compactMap { $0 })
    }

    /// Starts what the visible tab now needs and stops what it no longer does. A sampler that
    /// starts reads at once, so a tab never opens on a stale feed; one that keeps running keeps
    /// its rhythm, so calling this on every tab switch costs nothing extra.
    func update(isVisible: Bool, feeds: Set<SharedFeed>) {
        let wanted = Self.wanted(isVisible: isVisible, feeds: feeds)
        let fastStats = self.fastStats
        let sampleFast = self.sampleFast
        fastTimer = reconciled(fastTimer, isWanted: wanted.contains(.fastStats), interval: fastInterval, on: fastQueue) {
            fastStats.send(sampleFast())
        }
        let processes = self.processes
        let sampleProcesses = self.sampleProcesses
        processTimer = reconciled(processTimer, isWanted: wanted.contains(.processes), interval: processInterval, on: processQueue) {
            processes.send(sampleProcesses())
        }
    }

    private func reconciled(
        _ timer: DispatchSourceTimer?,
        isWanted: Bool,
        interval: TimeInterval,
        on queue: DispatchQueue,
        tick: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer? {
        switch (timer, isWanted) {
        case (let running?, true):
            return running
        case (let running?, false):
            running.cancel()
            return nil
        case (nil, true):
            return started(interval: interval, on: queue, tick: tick)
        case (nil, false):
            return nil
        }
    }

    /// Reads once straight away, then every `interval` with a tenth of it as leeway — the same
    /// allowance PluginScheduler gives a plugin's timer. The first reading is queued directly
    /// rather than left to the timer, whose leeway would let the system defer it by up to a
    /// second on the 10-second sampler.
    private func started(interval: TimeInterval, on queue: DispatchQueue, tick: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        queue.async(execute: tick)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler(handler: tick)
        timer.resume()
        return timer
    }
}

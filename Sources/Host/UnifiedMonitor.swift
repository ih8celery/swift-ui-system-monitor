import AppKit
import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// What is left of the one monitor while the tabs move into bundles: the samplers the
/// compiled-in tabs still need, keyed by MonitorMode. The 1-second and process readings are the
/// host's now (HostSamplers); this class only mirrors those feeds for the panels still compiled in.
final class UnifiedMonitor: ObservableObject {
    @Published var fastStats = FastStatsSnapshot()
    @Published var processSummary = ProcessSummary()
    @Published var networkSummary = NetworkSummary()
    @Published var isSpeedTestRunning = false
    @Published var speedTestStatus = "Ready"
    @Published var speedTestHealth = SampleHealth.ok
    @Published var speedTestResult: SpeedTestResult?

    // slowQueue is the sole owner of isWindowVisible/activeMode: every read or
    // write of that pair happens here, so the per-collector queues below can
    // run each check's own syscalls concurrently without racing on it.
    private let slowQueue = DispatchQueue(label: "systembar.monitor.slow", qos: .utility)
    let dnsQueue = DispatchQueue(label: "systembar.monitor.dns", qos: .utility)
    let speedTestQueue = DispatchQueue(label: "systembar.monitor.speedtest", qos: .utility)
    private let networkQueue = DispatchQueue(label: "systembar.monitor.network", qos: .utility)
    private var timers: [DispatchSourceTimer] = []
    private var feedSinks: [AnyCancellable] = []
    var isCollectingNetwork = false
    var hostnameCache: [String: HostnameCacheEntry] = [:]
    var hostnameLookupsInFlight = Set<String>()
    private var isWindowVisible = false
    private var activeMode: MonitorMode?

    var currentDownloadRate: Double { fastStats.currentDownloadRate }
    var currentUploadRate: Double { fastStats.currentUploadRate }
    var cpuUsagePercent: Double { fastStats.cpuUsagePercent }
    var cpuHistory: [Double] { fastStats.cpuHistory }
    var downloadHistory: [Double] { fastStats.downloadHistory }
    var uploadHistory: [Double] { fastStats.uploadHistory }
    var topCPUProcesses: [ProcessSnapshot] { processSummary.topCPU }
    var totalProcessCount: Int { processSummary.totalCount }
    var networkProcesses: [NetworkProcessSnapshot] { networkSummary.processes }
    var networkProcessCount: Int { networkSummary.totalProcessCount }
    var networkMaxCombinedRate: Double { networkSummary.maxCombinedRate }
    var destinations: [NetworkDestination] { networkSummary.destinations }
    var resolvedHostnames: [String: String] { networkSummary.resolvedHostnames }
    var networkStatus: String { networkSummary.status }
    var networkHealth: SampleHealth { networkSummary.health }

    /// The compiled-in tabs reach the one monitor through this until each owns its own
    /// collector. Deleted with the class.
    static let shared = UnifiedMonitor()

    private init() {
        timers = [
            makeTimer(every: MonitorSamplingPlan.networkRefreshInterval, leeway: .seconds(5), job: .network),
        ]
    }

    deinit {
        timers.forEach { $0.cancel() }
    }

    private func makeTimer(every interval: TimeInterval, leeway: DispatchTimeInterval, job: MonitorJob) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: slowQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.collectIfVisible(job) }
        timer.resume()
        return timer
    }

    func updatePresentation(isVisible: Bool, mode: MonitorMode?) {
        slowQueue.async { [weak self] in
            guard let self else { return }
            let becameVisible = isVisible && !self.isWindowVisible
            let changed = mode != self.activeMode
            self.isWindowVisible = isVisible
            self.activeMode = mode

            if becameVisible || changed {
                self.visibleJobs.forEach { self.run($0) }
            }
        }
    }

    /// The panels still compiled in read the host's feeds through here until each moves into
    /// its bundle and reads the feed itself.
    func follow(processes: Feed<ProcessSummary>, fastStats: Feed<FastStatsSnapshot>) {
        processSummary = processes.value
        self.fastStats = fastStats.value
        feedSinks = [
            processes.publisher.sink { [weak self] in self?.processSummary = $0 },
            fastStats.publisher.sink { [weak self] in self?.fastStats = $0 },
        ]
    }

    private var visibleJobs: Set<MonitorJob> {
        guard isWindowVisible, let activeMode else { return [] }
        return MonitorSamplingPlan.jobs(isVisible: true, mode: activeMode)
    }

    private func collectIfVisible(_ job: MonitorJob) {
        guard visibleJobs.contains(job) else { return }
        run(job)
    }

    // Each check hops from slowQueue to its own dedicated queue here, so a
    // slow one (network's nettop alone takes ~1s by design) can't hold up
    // the others.
    private func run(_ job: MonitorJob) {
        switch job {
        case .network: networkQueue.async { [weak self] in self?.collectNetwork() }
        }
    }
}

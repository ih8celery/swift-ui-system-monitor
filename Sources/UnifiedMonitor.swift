import AppKit
import Foundation
import SwiftUI

final class UnifiedMonitor: ObservableObject {
    @Published var fastStats = FastStatsSnapshot()
    @Published var memoryStats = MemoryStatsSnapshot()
    @Published var processSummary = ProcessSummary()
    @Published var networkSummary = NetworkSummary()
    @Published var powerSnapshot = PowerSnapshot()
    @Published var developerSnapshot = DeveloperSnapshot()
    @Published var diskSnapshot = DiskSnapshot()
    @Published var isSpeedTestRunning = false
    @Published var speedTestStatus = "Ready"
    @Published var speedTestHealth = SampleHealth.ok
    @Published var speedTestResult: SpeedTestResult?

    private let fastQueue = DispatchQueue(label: "systembar.monitor.fast", qos: .utility)
    // slowQueue is the sole owner of isWindowVisible/activeMode: every read or
    // write of that pair happens here, so the per-collector queues below can
    // run each check's own syscalls concurrently without racing on it.
    private let slowQueue = DispatchQueue(label: "systembar.monitor.slow", qos: .utility)
    let dnsQueue = DispatchQueue(label: "systembar.monitor.dns", qos: .utility)
    let speedTestQueue = DispatchQueue(label: "systembar.monitor.speedtest", qos: .utility)
    private let memoryQueue = DispatchQueue(label: "systembar.monitor.memory", qos: .utility)
    private let processQueue = DispatchQueue(label: "systembar.monitor.process", qos: .utility)
    private let networkQueue = DispatchQueue(label: "systembar.monitor.network", qos: .utility)
    private let powerQueue = DispatchQueue(label: "systembar.monitor.power", qos: .utility)
    private let developerQueue = DispatchQueue(label: "systembar.monitor.developer", qos: .utility)
    private var memoryTimer: DispatchSourceTimer?
    private var processTimer: DispatchSourceTimer?
    private var networkTimer: DispatchSourceTimer?
    private var powerTimer: DispatchSourceTimer?
    private var developerTimer: DispatchSourceTimer?
    private var diskTimer: DispatchSourceTimer?
    private var fastTimer: DispatchSourceTimer?
    let diskQueue = DispatchQueue(label: "systembar.monitor.disk", qos: .utility)
    /// The hog scan gets its own queue: it can run for minutes, and sharing diskQueue would
    /// stall the 30s capacity read behind it — freezing the rest of the Disk tab. It also
    /// owns `isScanningDiskHogs` and `lastDiskHogScan`, which are touched from nowhere else.
    let diskHogQueue = DispatchQueue(label: "systembar.monitor.diskhogs", qos: .utility)
    var isCollectingMemory = false
    var isCollectingProcesses = false
    var isCollectingNetwork = false
    var isCollectingPower = false
    var isCollectingDeveloper = false
    var isCollectingDisk = false
    var isScanningDiskHogs = false
    var lastDiskHogScan = Date.distantPast
    var lastPressureRefresh = Date.distantPast
    var cachedPressure: Double?
    var cachedGPU = GPUSnapshot()
    var lastFastStats = FastStatsSnapshot()
    var previousCPUCounters: CPUCounters?
    var previousNetworkCounters: NetworkCounters?
    var previousNetworkDate: Date?
    var hostnameCache: [String: HostnameCacheEntry] = [:]
    var hostnameLookupsInFlight = Set<String>()
    private var isWindowVisible = false
    private var activeMode = MonitorMode.memory

    var memory: MemorySnapshot { memoryStats.memory }
    var gpu: GPUSnapshot { memoryStats.gpu }
    var pressure: Double? { memoryStats.pressure }
    var pressureHistory: [Double] { memoryStats.pressureHistory }
    var lastUpdated: Date? { memoryStats.lastUpdated }
    var currentDownloadRate: Double { fastStats.currentDownloadRate }
    var currentUploadRate: Double { fastStats.currentUploadRate }
    var cpuUsagePercent: Double { fastStats.cpuUsagePercent }
    var cpuHistory: [Double] { fastStats.cpuHistory }
    var downloadHistory: [Double] { fastStats.downloadHistory }
    var uploadHistory: [Double] { fastStats.uploadHistory }
    var topMemoryProcesses: [ProcessSnapshot] { processSummary.topMemory }
    var topCPUProcesses: [ProcessSnapshot] { processSummary.topCPU }
    var totalProcessCount: Int { processSummary.totalCount }
    var maxPhysicalProcessMemory: UInt64 { processSummary.maxPhysical }
    var networkProcesses: [NetworkProcessSnapshot] { networkSummary.processes }
    var networkProcessCount: Int { networkSummary.totalProcessCount }
    var networkMaxCombinedRate: Double { networkSummary.maxCombinedRate }
    var destinations: [NetworkDestination] { networkSummary.destinations }
    var resolvedHostnames: [String: String] { networkSummary.resolvedHostnames }
    var networkStatus: String { networkSummary.status }
    var networkHealth: SampleHealth { networkSummary.health }
    var power: PowerSnapshot { powerSnapshot }
    var developer: DeveloperSnapshot { developerSnapshot }
    var disk: DiskSnapshot { diskSnapshot }

    init() {
        start()
    }

    func start() {
        guard fastTimer == nil else { return }

        let fastTimer = DispatchSource.makeTimerSource(queue: slowQueue)
        fastTimer.schedule(
            deadline: .now() + MonitorSamplingPlan.fastRefreshInterval,
            repeating: MonitorSamplingPlan.fastRefreshInterval,
            leeway: .milliseconds(200)
        )
        fastTimer.setEventHandler { [weak self] in
            self?.collectFastStatsIfVisible()
        }
        fastTimer.resume()
        self.fastTimer = fastTimer

        let memoryTimer = DispatchSource.makeTimerSource(queue: slowQueue)
        memoryTimer.schedule(
            deadline: .now() + MonitorSamplingPlan.memoryRefreshInterval,
            repeating: MonitorSamplingPlan.memoryRefreshInterval,
            leeway: .seconds(1)
        )
        memoryTimer.setEventHandler { [weak self] in
            self?.collectMemoryIfVisible()
        }
        memoryTimer.resume()
        self.memoryTimer = memoryTimer

        let processTimer = DispatchSource.makeTimerSource(queue: slowQueue)
        processTimer.schedule(
            deadline: .now() + MonitorSamplingPlan.processRefreshInterval,
            repeating: MonitorSamplingPlan.processRefreshInterval,
            leeway: .seconds(2)
        )
        processTimer.setEventHandler { [weak self] in
            self?.collectProcessesIfVisible()
        }
        processTimer.resume()
        self.processTimer = processTimer

        let networkTimer = DispatchSource.makeTimerSource(queue: slowQueue)
        networkTimer.schedule(
            deadline: .now() + MonitorSamplingPlan.networkRefreshInterval,
            repeating: MonitorSamplingPlan.networkRefreshInterval,
            leeway: .seconds(5)
        )
        networkTimer.setEventHandler { [weak self] in
            self?.collectNetworkIfVisible()
        }
        networkTimer.resume()
        self.networkTimer = networkTimer

        let powerTimer = DispatchSource.makeTimerSource(queue: slowQueue)
        powerTimer.schedule(
            deadline: .now() + MonitorSamplingPlan.powerRefreshInterval,
            repeating: MonitorSamplingPlan.powerRefreshInterval,
            leeway: .seconds(10)
        )
        powerTimer.setEventHandler { [weak self] in
            self?.collectPowerIfVisible()
        }
        powerTimer.resume()
        self.powerTimer = powerTimer

        let developerTimer = DispatchSource.makeTimerSource(queue: slowQueue)
        developerTimer.schedule(
            deadline: .now() + MonitorSamplingPlan.developerRefreshInterval,
            repeating: MonitorSamplingPlan.developerRefreshInterval,
            leeway: .seconds(10)
        )
        developerTimer.setEventHandler { [weak self] in
            self?.collectDeveloperIfVisible()
        }
        developerTimer.resume()
        self.developerTimer = developerTimer

        let diskTimer = DispatchSource.makeTimerSource(queue: slowQueue)
        diskTimer.schedule(
            deadline: .now() + MonitorSamplingPlan.diskRefreshInterval,
            repeating: MonitorSamplingPlan.diskRefreshInterval,
            leeway: .seconds(5)
        )
        diskTimer.setEventHandler { [weak self] in
            self?.collectDiskIfVisible()
        }
        diskTimer.resume()
        self.diskTimer = diskTimer
    }

    func updatePresentation(isVisible: Bool, mode: MonitorMode) {
        slowQueue.async { [weak self] in
            guard let self else { return }
            let becameVisible = isVisible && !self.isWindowVisible
            let modeChanged = mode != self.activeMode
            self.isWindowVisible = isVisible
            self.activeMode = mode

            if becameVisible || modeChanged {
                self.collectVisibleStats()
            }
        }
    }

    deinit {
        fastTimer?.cancel()
        memoryTimer?.cancel()
        processTimer?.cancel()
        networkTimer?.cancel()
        powerTimer?.cancel()
        developerTimer?.cancel()
        diskTimer?.cancel()
    }

    private var visibleJobs: Set<MonitorJob> {
        MonitorSamplingPlan.jobs(isVisible: isWindowVisible, mode: activeMode)
    }

    // Each check hops from slowQueue to its own dedicated queue here, so a
    // slow one (network's nettop alone takes ~1s by design) can't hold up
    // the others: they no longer share a single serial queue.
    private func collectVisibleStats() {
        if isWindowVisible {
            fastQueue.async { [weak self] in self?.collectFastStats() }
        }
        let jobs = visibleJobs
        if jobs.contains(.memory) {
            memoryQueue.async { [weak self] in self?.collectMemory() }
        }
        if jobs.contains(.processes) {
            processQueue.async { [weak self] in self?.collectProcesses() }
        }
        if jobs.contains(.network) {
            networkQueue.async { [weak self] in self?.collectNetwork() }
        }
        if jobs.contains(.power) {
            powerQueue.async { [weak self] in self?.collectPower() }
        }
        if jobs.contains(.developer) {
            developerQueue.async { [weak self] in self?.collectDeveloper() }
        }
        if jobs.contains(.disk) {
            diskQueue.async { [weak self] in self?.collectDisk() }
        }
    }

    private func collectMemoryIfVisible() {
        guard visibleJobs.contains(.memory) else { return }
        memoryQueue.async { [weak self] in self?.collectMemory() }
    }

    private func collectProcessesIfVisible() {
        guard visibleJobs.contains(.processes) else { return }
        processQueue.async { [weak self] in self?.collectProcesses() }
    }

    private func collectNetworkIfVisible() {
        guard visibleJobs.contains(.network) else { return }
        networkQueue.async { [weak self] in self?.collectNetwork() }
    }

    private func collectPowerIfVisible() {
        guard visibleJobs.contains(.power) else { return }
        powerQueue.async { [weak self] in self?.collectPower() }
    }

    private func collectDeveloperIfVisible() {
        guard visibleJobs.contains(.developer) else { return }
        developerQueue.async { [weak self] in self?.collectDeveloper() }
    }

    private func collectDiskIfVisible() {
        guard visibleJobs.contains(.disk) else { return }
        diskQueue.async { [weak self] in self?.collectDisk() }
    }

    private func collectFastStatsIfVisible() {
        guard isWindowVisible else { return }
        fastQueue.async { [weak self] in self?.collectFastStats() }
    }

}

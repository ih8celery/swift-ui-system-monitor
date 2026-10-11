import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Disk tab as a bundle. The host calls `collect()` every 30 s while the tab shows and, unless
/// settings turn it off, every 15 minutes while it is hidden. Each call reads the volumes on the
/// plugin's queue, then asks the scan queue to run whichever plans are due. The scan queue is the
/// plugin's own and serial: it alone touches the ledger, a plan can run for minutes without
/// holding up a volume read, and the panel's rescan button queues a forced run behind whatever
/// is going. Everything publishes on main, and the panel observes `snapshot`.
@objc(SystemBarDiskPlugin)
public final class DiskPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "disk"
    public let title = "Disk"
    public let systemImage = "internaldrive"
    public let accent = Palette.cyan
    public let refreshInterval: TimeInterval = DiskSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = []
    /// 15 minutes, or nil when `backgroundScans` is false in this tab's settings: the host then
    /// never calls `collect()` while the tab is hidden, and scans run only on the button and
    /// while the tab shows.
    public let backgroundInterval: TimeInterval?

    static let backgroundScansKey = "backgroundScans"

    @Published private(set) var snapshot = DiskSnapshot()

    private let host: HostServices
    private let collector: DiskCollector
    private let scanner: DiskScanner
    private let store: DiskLedgerStore
    private let plans: [DiskScanPlan]
    private let now: () -> Date
    private let scanQueue = DispatchQueue(label: "systembar.disk.scan", qos: .utility)
    /// Touched only on `scanQueue`.
    private var ledger = DiskLedger()
    private var isLedgerLoaded = false
    /// When each plan last started a run, measured or not. Touched only on `scanQueue`; lost at
    /// relaunch, which costs at most one extra attempt per plan per launch.
    private var lastAttempt: [DiskPlanKind: Date] = [:]
    /// A rescan is queued or running, so another click adds nothing. Set by the caller and
    /// cleared on `scanQueue`, so it sits behind a lock rather than on one queue.
    private let forcedRunLock = NSLock()
    private var isForcedRunQueued = false

    @MainActor public convenience init(host: HostServices) {
        self.init(host: host, plans: DiskScanPlan.all, now: { Date() }, listChildren: DiskScanner.subfolders(of:))
    }

    /// The plans, clock and folder listing are parameters so a test can run a tiny plan over a
    /// fake tree in no time; the app uses `init(host:)`.
    @MainActor init(host: HostServices, plans: [DiskScanPlan], now: @escaping () -> Date, listChildren: @escaping (String) -> [String]?) {
        self.host = host
        collector = DiskCollector(host: host)
        scanner = DiskScanner(host: host, listChildren: listChildren)
        store = DiskLedgerStore.standard(dataDirectory: host.dataDirectory)
        self.plans = plans
        self.now = now
        let setting = Self.backgroundScansSetting(host.settings)
        backgroundInterval = setting.isEnabled ? DiskSampling.backgroundInterval : nil
        var initial = DiskSnapshot()
        initial.settingsProblem = setting.problem
        snapshot = initial
        super.init()
    }

    /// `backgroundScans`: absent or true means on; false means off; anything else keeps the
    /// default and is reported, because a misspelt value must never silently do nothing.
    static func backgroundScansSetting(_ settings: PluginSettings) -> (isEnabled: Bool, problem: String?) {
        if let flag = settings.bool(forKey: backgroundScansKey) { return (flag, nil) }
        if settings[backgroundScansKey] != nil {
            return (true, "settings: \"\(backgroundScansKey)\" must be true or false; background scans stay on")
        }
        return (true, nil)
    }

    public func collect() {
        let reading = collector.readVolumes()
        publish { $0.applying(reading) }
        requestScan(force: false)
    }

    /// The panel's rescan button passes `force: true`; every collect asks without forcing. Runs
    /// behind any scan already going, which then finds nothing due unless forced.
    /// A click while a rescan is already queued or running is ignored rather than queuing
    /// another full run behind it.
    func requestScan(force: Bool) {
        if force {
            let isAlreadyQueued = forcedRunLock.withLock {
                defer { isForcedRunQueued = true }
                return isForcedRunQueued
            }
            guard !isAlreadyQueued else { return }
        }
        scanQueue.async { [self] in
            loadLedgerIfNeeded()
            runDuePlans(force: force)
            if force { forcedRunLock.withLock { isForcedRunQueued = false } }
        }
    }

    /// For tests: returns once everything queued on the scan queue so far has finished, so a
    /// test can check that something did not happen without guessing how long to wait.
    func drainScanQueue() {
        scanQueue.sync {}
    }

    // MARK: - Scan queue

    private func loadLedgerIfNeeded() {
        guard !isLedgerLoaded else { return }
        isLedgerLoaded = true
        switch store.load() {
        case .fresh:
            break
        case .loaded(let saved):
            ledger = saved
        case let .movedAside(to, reason):
            host.log("SystemBar Disk: the saved ledger could not be read (\(reason)); moved to \(to)")
            publish { $0.noting("Saved sizes could not be read (\(reason)); the file was moved to \(to) and a fresh one started") }
        }
        publishLedger()
    }

    private func runDuePlans(force: Bool) {
        let due = plans.filter { force || isDue($0) }
        guard !due.isEmpty else { return }
        for plan in due {
            lastAttempt[plan.kind] = now()
            publish { $0.scanning(true, status: "Measuring \(plan.kind.title.lowercased()) folders") }
            var fresh: [DiskSample] = []
            let outcome = scanner.run(plan: plan, previous: ledger) { sample in
                // Each tree lands in the list as it finishes rather than after the last one.
                fresh.append(sample)
                publishRows(from: ledger.appending(fresh))
            }
            ledger = ledger.appending(fresh).compacted(now: now())
            save()
            publish { $0.scanning(false, status: "\(plan.kind.title): \(outcome.status)") }
            publishLedger()
        }
    }

    /// Due when the ledger's newest sample for the plan is a cadence old and so is its last
    /// attempt. Attempts count because a run can record nothing (no simulator folder, every row
    /// too slow), and the ledger alone would then call the plan due on every collect.
    private func isDue(_ plan: DiskScanPlan) -> Bool {
        let at = now()
        let hasWaitedSinceAttempt = lastAttempt[plan.kind].map { at.timeIntervalSince($0) >= plan.cadence } ?? true
        return hasWaitedSinceAttempt && ledger.isDue(plan.kind, cadence: plan.cadence, now: at)
    }

    private func save() {
        do {
            try store.save(ledger)
            publish { $0.savingProblem(nil) }
        } catch {
            let path = store.fileURL.path
            let reason = error.localizedDescription
            host.log("SystemBar Disk: could not save the ledger to \(path): \(reason)")
            publish { $0.savingProblem("Sizes could not be saved to \(path): \(reason)") }
        }
    }

    private func publishLedger() {
        publishRows(from: ledger)
    }

    /// Reads the home folder and the clock here, on the scan queue, so the closure that runs on
    /// main carries only values.
    private func publishRows(from ledger: DiskLedger) {
        let homeDirectory = host.homeDirectory
        let at = now()
        publish { $0.applying(ledger: ledger, homeDirectory: homeDirectory, now: at) }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(DiskPanel(plugin: self))
    }

    /// Readings arrive on the plugin's queue and on the scan queue; the panel observes from main.
    private func publish(_ change: @escaping (DiskSnapshot) -> DiskSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = change(self.snapshot)
        }
    }
}

import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The CPU tab as a bundle. The headline, graph, cluster bars and user/system split follow the
/// host's 1-second feed and the list follows its process feed. `collect()` reads what the feed
/// does not carry (load average, thermal state, `pmset -g therm`) every ten seconds while the
/// tab is showing, and again whenever macOS says the thermal state changed. The one other
/// command it runs is a `ps` when a row is tapped, which the panel calls off the main thread.
/// This plugin also calls `collect()` from its own thermal queue, so the SDK's "never
/// concurrently with itself" promise does not cover it.
@objc(SystemBarCPUPlugin)
public final class CPUPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "cpu"
    public let title = "CPU"
    public let systemImage = "cpu"
    public let accent = Palette.warning
    public let refreshInterval: TimeInterval = CPUSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = [.processes, .fastStats]

    @Published private(set) var fastStats = FastStatsSnapshot()
    @Published private(set) var processes = ProcessSummary()
    @Published private(set) var machineState = MachineState.empty
    /// Read once at init: a chip does not change. Nil means the view draws per-core bars with
    /// no cluster names.
    let clusters: [CPUCluster]?
    private let host: HostServices
    private var feedSubscriptions: [AnyCancellable] = []
    private var thermalObserver: NSObjectProtocol?
    /// Runs the thermal-change observer off the main thread, as the host's own calls are.
    private let thermalQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    @MainActor public init(host: HostServices) {
        self.host = host
        clusters = CPUCollector.clusters()
        super.init()
        fastStats = host.fastStats.value
        processes = host.processes.value
        feedSubscriptions = [
            host.fastStats.publisher.sink { [weak self] snapshot in self?.fastStats = snapshot },
            host.processes.publisher.sink { [weak self] summary in self?.processes = summary },
        ]
        observeThermalChanges()
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    /// A change is worth one read now rather than up to ten seconds later. Registered from a
    /// plain method, not the main-actor init, so the compiler does not take `self` for a
    /// main-actor value being sent to the observer block.
    private func observeThermalChanges() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: thermalQueue
        ) { [weak self] _ in self?.collect() }
    }

    /// Reads the load average, thermal state and pmset's speed limit, and publishes them on the
    /// main thread, where the panel observes them. A reading older than the one showing is
    /// dropped, because the thermal observer can run a collect alongside the scheduled one.
    public func collect() {
        let state = CPUCollector.machineState(using: host)
        DispatchQueue.main.async { [weak self] in
            guard let self, state.sampledAt >= self.machineState.sampledAt else { return }
            self.machineState = state
        }
    }

    /// The tapped group's processes, from a fresh `ps`. Blocking: the panel calls it off main.
    func groupDetail(named name: String) -> [ProcessDetail] {
        ProcessDetail.fetchGroupDetail(name: name, using: host)
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(CPUPanel(plugin: self))
    }
}

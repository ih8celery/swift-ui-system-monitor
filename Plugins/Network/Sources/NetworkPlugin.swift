import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Network tab as a bundle. The host calls `collect()` on this plugin's queue every 30 s while
/// the tab shows; each collect runs nettop and lsof, publishes on main, then asks the collector for
/// the destinations' hostnames, which it looks up on its own DNS queue. The rate cards and graph
/// follow the host's 1-second feed, and the speed test runs only when the panel's button is
/// pressed, on its own queue.
@objc(SystemBarNetworkPlugin)
public final class NetworkPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "network"
    public let title = "Network"
    public let systemImage = "arrow.up.arrow.down"
    public let accent = Palette.blue
    public let refreshInterval: TimeInterval = NetworkSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = [.fastStats]

    @Published private(set) var summary = NetworkSummary()
    @Published private(set) var fastStats = FastStatsSnapshot()
    @Published private(set) var speedTest = SpeedTestState()
    private let host: HostServices
    private let collector: NetworkCollector
    /// A speed test runs for up to 30 seconds, so it gets its own queue rather than holding up
    /// the plugin's collects.
    private let speedTestQueue = DispatchQueue(label: "systembar.network.speedtest", qos: .utility)
    private var feedSubscription: AnyCancellable?

    @MainActor public init(host: HostServices) {
        self.host = host
        collector = NetworkCollector(host: host)
        super.init()
        fastStats = host.fastStats.value
        feedSubscription = host.fastStats.publisher.sink { [weak self] snapshot in
            self?.fastStats = snapshot
        }
    }

    public func collect() {
        let reading = collector.sample()
        DispatchQueue.main.async { [weak self] in
            self?.show(reading)
        }
    }

    /// Main thread: the panel's button. Does nothing while a test is already running.
    func runSpeedTest() {
        guard !speedTest.isRunning else { return }
        speedTest = speedTest.started()
        let host = self.host
        let startedAt = Date()
        speedTestQueue.async { [weak self] in
            let outcome = SpeedTest.measure(using: host, startedAt: startedAt)
            DispatchQueue.main.async {
                guard let self else { return }
                self.speedTest = self.speedTest.finished(with: outcome)
            }
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(NetworkPanel(plugin: self))
    }

    /// Main thread: shows a sample, then asks for the names of its destinations. Both write
    /// `summary` as a change to its current value, so a lookup that finishes between two samples
    /// is never lost.
    private func show(_ reading: NetworkReading) {
        summary = summary.applying(reading)
        collector.resolveHostnames(for: reading.destinations) { [weak self] address, hostname in
            guard let self else { return }
            self.summary = self.summary.resolving(address, to: hostname)
        }
    }
}

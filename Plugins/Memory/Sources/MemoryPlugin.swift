import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Memory tab as a bundle. The host calls `collect()` on this plugin's queue every 3 seconds
/// while the tab shows; each collect reads the kernel's memory figures (memory_pressure and ioreg
/// only every 30 seconds) and publishes on main. The top-memory list follows the process feed.
@objc(SystemBarMemoryPlugin)
public final class MemoryPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "memory"
    public let title = "Memory"
    public let systemImage = "memorychip"
    public let accent = Palette.good
    public let refreshInterval: TimeInterval = MemorySampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = [.processes]

    @Published private(set) var stats = MemoryStatsSnapshot()
    @Published private(set) var processes = ProcessSummary()
    private let collector: MemoryCollector
    private var feedSubscription: AnyCancellable?

    @MainActor public init(host: HostServices) {
        collector = MemoryCollector(host: host)
        super.init()
        processes = host.processes.value
        feedSubscription = host.processes.publisher.sink { [weak self] summary in
            self?.processes = summary
        }
    }

    public func collect() {
        let reading = collector.sample()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stats = self.stats.recording(reading)
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(MemoryPanel(plugin: self))
    }
}

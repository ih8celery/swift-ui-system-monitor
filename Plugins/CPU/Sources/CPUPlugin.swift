import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The CPU tab as a bundle. The headline and graph follow the host's 1-second feed and the
/// list and process count follow its process feed, so `collect()` has nothing to do. The one
/// command it runs is a `ps` when a row is tapped, which the panel calls off the main thread.
@objc(SystemBarCPUPlugin)
public final class CPUPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "cpu"
    public let title = "CPU"
    public let systemImage = "cpu"
    public let accent = Palette.warning
    /// A day: the longest the host allows (PluginScheduler.maximumRefreshInterval, which a
    /// bundle cannot name). collect() has nothing to do, so the less often it is called the better.
    public let refreshInterval: TimeInterval = 86_400
    public let sharedFeeds: Set<SharedFeed> = [.processes, .fastStats]

    @Published private(set) var fastStats = FastStatsSnapshot()
    @Published private(set) var processes = ProcessSummary()
    private let host: HostServices
    private var feedSubscriptions: [AnyCancellable] = []

    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
        fastStats = host.fastStats.value
        processes = host.processes.value
        feedSubscriptions = [
            host.fastStats.publisher.sink { [weak self] snapshot in self?.fastStats = snapshot },
            host.processes.publisher.sink { [weak self] summary in self?.processes = summary },
        ]
    }

    /// Everything this tab shows comes from the two shared feeds, which the host samples while
    /// the tab is visible, so there is nothing of its own to sample.
    public func collect() {}

    /// The tapped group's processes, from a fresh `ps`. Blocking: the panel calls it off main.
    func groupDetail(named name: String) -> [ProcessDetail] {
        ProcessDetail.fetchGroupDetail(name: name, using: host)
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(CPUPanel(plugin: self))
    }
}

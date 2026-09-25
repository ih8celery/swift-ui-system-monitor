import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Dev tab as a bundle. The host calls `collect()` on this plugin's queue once a minute while
/// the tab shows; each collect blocks for the one-second rusage window, grades the machine with
/// the host's 1-second CPU figure, and publishes the snapshot on main for the panel to observe.
@objc(SystemBarDevPlugin)
public final class DevPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "dev"
    public let title = "Dev"
    public let systemImage = "terminal"
    public let accent = Palette.purple
    public let refreshInterval: TimeInterval = DevSampling.refreshInterval
    /// The capacity grade reads the 1-second CPU figure. That sampler runs for every visible tab
    /// anyway, but the declaration says what this tab depends on.
    public let sharedFeeds: Set<SharedFeed> = [.fastStats]

    @Published private(set) var capacity = CapacitySnapshot()
    private let host: HostServices

    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
    }

    public func collect() {
        let next = CapacityCollector.collect(using: host)
        DispatchQueue.main.async { [weak self] in
            self?.capacity = next
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(DeveloperPanel(plugin: self))
    }
}

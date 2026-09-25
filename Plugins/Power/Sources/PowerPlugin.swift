import AppKit
import Foundation
import SwiftUI
import SystemBarKit

/// The Power tab as a bundle. The host calls `collect()` on this plugin's queue once a minute
/// while the tab shows; the snapshot is published on the main thread and the panel observes it.
@objc(SystemBarPowerPlugin)
public final class PowerPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "power"
    public let title = "Power"
    public let systemImage = "bolt.heart"
    public let accent = Palette.caution
    public let refreshInterval: TimeInterval = 60
    public let sharedFeeds: Set<SharedFeed> = [.processes]

    @Published var snapshot = PowerSnapshot()
    private let host: HostServices

    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
    }

    public func collect() {
        var next = PowerCollector.collect(using: host)
        next.contributors = PowerCollector.contributors(from: host.processes.value.topCPU)
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = next
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(PowerPanel(plugin: self))
    }
}

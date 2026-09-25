import Combine
import Foundation
import SwiftUI
import SystemBarKit

@objc(SystemBarDiskPlugin)
public final class DiskPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "disk"
    public let title = "Disk"
    public let systemImage = "internaldrive"
    public let accent = Palette.cyan
    public let refreshInterval: TimeInterval = DiskSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = []

    @Published private(set) var snapshot = DiskSnapshot()
    private let collector: DiskCollector

    @MainActor public init(host: HostServices) {
        collector = DiskCollector(host: host)
        super.init()
    }

    public func collect() {
        let reading = collector.readVolumes()
        publish { $0.applying(reading) }
        scanHogs(force: false)
    }

    /// The panel's rescan button passes `force: true`; every collect asks without forcing.
    func scanHogs(force: Bool) {
        collector.scanHogsIfDue(force: force) { [weak self] update in
            self?.publish { $0.applying(update) }
        }
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

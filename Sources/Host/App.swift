import AppKit
import Foundation
import SwiftUI
import SystemBarKit

#if !TESTING
@main
struct SystemBarApp: App {
    private let tabs: [LoadedTab]
    private let configPath: String
    private let processes = Feed(initial: ProcessSummary())
    private let fastStats = Feed(initial: FastStatsSnapshot())
    private let scheduler = PluginScheduler()
    private let samplers: HostSamplers

    init() {
        let store = PluginConfigStore.standard()
        let host = HostServices(
            homeDirectory: NSHomeDirectory(),
            processes: processes,
            fastStats: fastStats,
            runner: ProcessRunner.run,
            log: { NSLog("%@", $0) }
        )
        samplers = HostSamplers.standard(processes: processes, fastStats: fastStats)
        let source = BundleTabSource.standard()
        let loaded = TabLoader.load(store: store, source: source, host: host)
        tabs = loaded
        configPath = store.fileURL.path

        // `SystemBar --list-plugins` is the loader as a command: it reports what the window
        // would show, then exits without one. test.sh will use it to check the real loader.
        if CommandLine.arguments.contains("--list-plugins") {
            PluginListReport.lines(for: loaded).forEach { print($0) }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(tabs: tabs, configPath: configPath, scheduler: scheduler, samplers: samplers)
        } label: {
            Image(systemName: "percent")
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
#endif

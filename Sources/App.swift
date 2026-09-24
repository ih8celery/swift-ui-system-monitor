import AppKit
import Foundation
import SwiftUI

#if !TESTING
@main
struct SystemBarApp: App {
    private let tabs: [LoadedTab]
    private let configPath: String

    init() {
        let store = PluginConfigStore.standard()
        let loaded = Self.loadTabs(store: store)
        tabs = loaded
        configPath = store.fileURL.path

        // `SystemBar --list-plugins` is the loader as a command: it reports what the window
        // would show, then exits without one. test.sh will use it to check the real loader.
        if CommandLine.arguments.contains("--list-plugins") {
            print(PluginListReport.lines(for: loaded).joined(separator: "\n"))
            exit(0)
        }
    }

    /// A file that cannot be read, parsed, or (on first launch) written gives one error tab
    /// naming the path and the reason, and nothing else: the fix is in the file, not the app.
    private static func loadTabs(store: PluginConfigStore) -> [LoadedTab] {
        let host = HostServices(
            homeDirectory: NSHomeDirectory(),
            runner: ProcessRunner.run,
            log: { NSLog("%@", $0) }
        )
        switch store.loadOrCreate(default: .builtins(named: BuiltinTabSource.defaultNames)) {
        case .success(let config):
            return TabCatalog.build(config: config, source: BuiltinTabSource(), host: host)
        case .failure(let error):
            return [.failed(location: store.fileURL.path, reason: error.description)]
        }
    }

    var body: some Scene {
        MenuBarExtra {
            // UnifiedMonitor.shared starts its timers when first created, so nothing else starts it.
            RootView(monitor: UnifiedMonitor.shared, tabs: tabs, configPath: configPath)
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

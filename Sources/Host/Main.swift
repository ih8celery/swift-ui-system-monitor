import AppKit
import Foundation
import SystemBarKit

#if !TESTING
/// Decides before SwiftUI starts: `--preview` shows one plugin and never reads plugins.json;
/// anything else is the menu bar app.
@main
enum SystemBarMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == PreviewOptions.flag else {
            MainActor.assumeIsolated { SystemBarApp.main() }
            return
        }
        MainActor.assumeIsolated { runPreview(arguments) }
    }

    @MainActor private static func runPreview(_ arguments: [String]) -> Never {
        _ = NSApplication.shared
        let processes = Feed(initial: ProcessSummary())
        let fastStats = Feed(initial: FastStatsSnapshot())
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemBar-preview-\(UUID().uuidString)", isDirectory: true)
        let outcome = PreviewCommand.prepare(
            arguments: arguments,
            currentDirectory: FileManager.default.currentDirectoryPath,
            source: BundleTabSource.standard(),
            dataRoot: dataRoot,
            processes: processes,
            fastStats: fastStats
        )
        switch outcome {
        case let .finished(code, message):
            if let message {
                fputs(message + "\n", code == PreviewExit.ok ? stdout : stderr)
            }
            try? FileManager.default.removeItem(at: dataRoot)
            exit(code)
        case let .openWindow(plugin, size):
            let presenter = TabPresenter(
                scheduler: PluginScheduler(),
                samplers: HostSamplers.standard(processes: processes, fastStats: fastStats)
            )
            PreviewWindow.run(plugin: plugin, size: size, presenter: presenter)
        }
    }
}
#endif

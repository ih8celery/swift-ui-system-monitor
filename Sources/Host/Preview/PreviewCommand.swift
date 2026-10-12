import CoreGraphics
import Foundation
import SystemBarKit

/// What a preview run comes to: done, with an exit code and something to print, or a plugin
/// that should now be shown in a window.
enum PreviewOutcome {
    case finished(code: Int32, message: String?)
    case openWindow(plugin: TabPlugin, size: CGSize)
}

/// `SystemBar --preview`, minus the parts that need a real app (printing, exiting, the window),
/// so every decision in it can be tested in process.
@MainActor
enum PreviewCommand {
    static func prepare(
        arguments: [String],
        currentDirectory: String,
        source: TabSource,
        dataRoot: URL,
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>
    ) -> PreviewOutcome {
        let options: PreviewOptions
        switch PreviewOptions.parse(arguments, currentDirectory: currentDirectory) {
        case .success(let parsed): options = parsed
        case .failure(let error): return badInput("\(error.description)\n\(PreviewOptions.usage)")
        }
        let settings: PluginSettings
        switch readSettings(options.settingsURL) {
        case .success(let read): settings = read
        case .failure(let error): return badInput(error.description)
        }
        let runner: CommandRunner
        switch readRunner(options.repliesURL) {
        case .success(let read): runner = read
        case .failure(let error): return badInput(error.description)
        }
        let host = HostServices(
            homeDirectory: NSHomeDirectory(),
            processes: processes,
            fastStats: fastStats,
            runner: runner,
            log: { NSLog("%@", $0) }
        )
        let tab = PreviewSession.load(bundlePath: options.bundlePath, settings: settings, source: source,
                                      host: host, dataRoot: dataRoot)
        guard let plugin = tab.plugin else {
            return .finished(code: PreviewExit.failed, message: PluginListReport.lines(for: [tab]).joined(separator: "\n"))
        }
        switch options.output {
        case .window:
            return .openWindow(plugin: plugin, size: options.size)
        case .png(let url):
            if let problem = PreviewRenderer.writePicture(of: plugin, size: options.size, to: url) {
                return .finished(code: PreviewExit.failed, message: problem)
            }
            return .finished(code: PreviewExit.ok, message: nil)
        }
    }

    private static func badInput(_ message: String) -> PreviewOutcome {
        .finished(code: PreviewExit.badInput, message: message)
    }

    private static func readSettings(_ url: URL?) -> Result<PluginSettings, PreviewInputError> {
        guard let url else { return .success(.empty) }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return .failure(PreviewInputError(description: "could not read the settings file \(url.path)"))
        }
        return PluginConfigParser.parseSettingsFile(data).mapError {
            PreviewInputError(description: "\(url.path): \($0.description)")
        }
    }

    private static func readRunner(_ url: URL?) -> Result<CommandRunner, PreviewInputError> {
        guard let url else { return .success(ProcessRunner.run) }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return .failure(PreviewInputError(description: "could not read the replies file \(url.path)"))
        }
        return CannedReplies.parse(data).map(CannedReplies.runner)
    }
}

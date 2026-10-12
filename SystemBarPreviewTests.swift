import AppKit
import Foundation
import SwiftUI
import SystemBarKit

/// Tests for `SystemBar --preview`: the settings and replies files, the command line, loading
/// one plugin, drawing it, and the command that ties them together.
@MainActor
struct SystemBarPreviewTests {
    static func runAll() {
        // ImageRenderer and NSHostingView expect an application object, as the real app has.
        _ = NSApplication.shared
        testSettingsFileReadsAnObject()
        testSettingsFileRejectsANonObject()
        testSettingsFileReportsMalformedJSON()
        testRepliesFileReadsRepliesWithDefaults()
        testRepliesFileRejectsAnUnknownKey()
        testRepliesFileRejectsAnUnknownReplyKey()
        testRepliesFileRejectsANonNumberStatus()
        testRepliesFileRejectsABooleanStatus()
        testRepliesFileRejectsAReplyWithoutPath()
        testCannedRunnerAnswersAnExactMatch()
        testCannedRunnerRefusesAnythingElseWith127()
        testOptionsReadAPictureRunWithEveryFlag()
        testOptionsReadAWindowRunWithTheDefaultSize()
        testOptionsRefuseAMissingBundle()
        testOptionsRefuseNeitherOrBothOutputs()
        testOptionsRefuseAnUnknownFlag()
        testOptionsRefuseAFlagWithoutItsValue()
        testOptionsRefuseABadSize()
        testSessionHandsThePluginItsSettingsAndAFolderUnderTheRoot()
        testSessionKeepsTheLoadersReason()
        testCollectOnceWaitsForTheUpdateOnMain()
        testCollectOnceGivesUpAfterItsTimeout()
        testPictureHasTheRequestedSizeAtTheRendererScale()
    }

    // MARK: - Settings file

    static func testSettingsFileReadsAnObject() {
        let data = Data(#"{ "command": "/opt/backup", "limit": 3 }"#.utf8)
        guard case .success(let settings) = PluginConfigParser.parseSettingsFile(data) else {
            return expect(false, "a settings object should parse")
        }
        expect(settings.string(forKey: "command") == "/opt/backup", "settings file keeps a string value")
        expect(settings.number(forKey: "limit") == 3, "settings file keeps a number value")
    }

    static func testSettingsFileRejectsANonObject() {
        guard case .failure(let error) = PluginConfigParser.parseSettingsFile(Data("[1, 2]".utf8)) else {
            return expect(false, "a list is not a settings object")
        }
        expect(error.description.contains("settings"), "the error names settings: \(error.description)")
    }

    static func testSettingsFileReportsMalformedJSON() {
        guard case .failure(let error) = PluginConfigParser.parseSettingsFile(Data("{".utf8)) else {
            return expect(false, "half a JSON object should not parse")
        }
        guard case .malformedJSON = error else {
            return expect(false, "malformed settings should be .malformedJSON, got \(error)")
        }
    }

    // MARK: - Canned replies

    static func repliesData(_ text: String) -> Data { Data(text.utf8) }

    static func testRepliesFileReadsRepliesWithDefaults() {
        let data = repliesData(#"""
        { "replies": [
          { "path": "/bin/date", "arguments": ["+%H"], "output": "12\n" },
          { "path": "/x/backup", "arguments": ["start"], "output": "", "error": "busy", "status": 1 }
        ] }
        """#)
        guard case .success(let replies) = CannedReplies.parse(data) else {
            return expect(false, "a good replies file should parse")
        }
        expect(replies == [
            CannedReply(path: "/bin/date", arguments: ["+%H"], output: "12\n", error: "", status: 0),
            CannedReply(path: "/x/backup", arguments: ["start"], output: "", error: "busy", status: 1),
        ], "replies keep their order, and error and status default to empty and 0: \(replies)")
    }

    static func testRepliesFileRejectsAnUnknownKey() {
        guard case .failure(let error) = CannedReplies.parse(repliesData(#"{ "replies": [], "extra": 1 }"#)) else {
            return expect(false, "an unknown top-level key should be refused")
        }
        expect(error.description.contains("\"extra\""), "the error names the key: \(error.description)")
    }

    static func testRepliesFileRejectsAnUnknownReplyKey() {
        let data = repliesData(#"{ "replies": [ { "path": "/a", "arguments": [], "output": "", "stdout": "" } ] }"#)
        guard case .failure(let error) = CannedReplies.parse(data) else {
            return expect(false, "an unknown reply key should be refused")
        }
        expect(error.description.contains("\"stdout\"") && error.description.contains("reply 1"),
               "the error names the key and the reply: \(error.description)")
    }

    static func testRepliesFileRejectsANonNumberStatus() {
        let data = repliesData(#"{ "replies": [ { "path": "/a", "arguments": [], "output": "", "status": "0" } ] }"#)
        guard case .failure(let error) = CannedReplies.parse(data) else {
            return expect(false, "a string status should be refused")
        }
        expect(error.description.contains("\"status\""), "the error names status: \(error.description)")
    }

    static func testRepliesFileRejectsABooleanStatus() {
        let data = repliesData(#"{ "replies": [ { "path": "/a", "arguments": [], "output": "", "status": true } ] }"#)
        guard case .failure = CannedReplies.parse(data) else {
            return expect(false, "a boolean status should be refused, not read as 1")
        }
    }

    static func testRepliesFileRejectsAReplyWithoutPath() {
        let data = repliesData(#"{ "replies": [ { "arguments": [], "output": "" } ] }"#)
        guard case .failure(let error) = CannedReplies.parse(data) else {
            return expect(false, "a reply without path should be refused")
        }
        expect(error.description.contains("\"path\""), "the error names path: \(error.description)")
    }

    static func testCannedRunnerAnswersAnExactMatch() {
        let runner = CannedReplies.runner([
            CannedReply(path: "/bin/date", arguments: ["+%H"], output: "12\n", error: "", status: 0),
        ])
        let reply = runner("/bin/date", ["+%H"], nil, 5)
        expect(reply.output == "12\n" && reply.status == 0 && !reply.didTimeout, "an exact match gets its reply: \(reply)")
    }

    static func testCannedRunnerRefusesAnythingElseWith127() {
        let runner = CannedReplies.runner([
            CannedReply(path: "/bin/date", arguments: ["+%H"], output: "12\n", error: "", status: 0),
        ])
        let reply = runner("/bin/date", ["+%M"], nil, 5)
        expect(reply.status == CannedReplies.missingStatus, "no match exits 127, got \(reply.status)")
        expect(reply.error == "no canned reply for /bin/date +%M", "no match says which command: \(reply.error)")
    }

    // MARK: - Command line

    static func options(_ words: [String]) -> Result<PreviewOptions, PreviewInputError> {
        PreviewOptions.parse([PreviewOptions.flag] + words, currentDirectory: "/work")
    }

    static func testOptionsReadAPictureRunWithEveryFlag() {
        let result = options(["Tab.bundle", "--png", "out/tab.png", "--replies", "/r.json",
                              "--settings", "s.json", "--size", "400x300"])
        guard case .success(let parsed) = result else { return expect(false, "a full picture run should parse: \(result)") }
        expect(parsed == PreviewOptions(
            bundlePath: "/work/Tab.bundle",
            output: .png(URL(fileURLWithPath: "/work/out/tab.png")),
            repliesURL: URL(fileURLWithPath: "/r.json"),
            settingsURL: URL(fileURLWithPath: "/work/s.json"),
            size: CGSize(width: 400, height: 300)
        ), "relative paths resolve against the current folder: \(parsed)")
    }

    static func testOptionsReadAWindowRunWithTheDefaultSize() {
        guard case .success(let parsed) = options(["/b/Tab.bundle", "--window"]) else {
            return expect(false, "a window run should parse")
        }
        expect(parsed.output == .window && parsed.size == PreviewOptions.defaultSize
               && parsed.repliesURL == nil && parsed.settingsURL == nil,
               "a window run has the default size and no files: \(parsed)")
    }

    static func testOptionsRefuseAMissingBundle() {
        guard case .failure(let error) = options(["--window"]) else { return expect(false, "no bundle should be refused") }
        expect(error.description.contains("bundle"), "the error asks for the bundle: \(error.description)")
    }

    static func testOptionsRefuseNeitherOrBothOutputs() {
        guard case .failure = options(["Tab.bundle"]) else { return expect(false, "no output should be refused") }
        guard case .failure = options(["Tab.bundle", "--window", "--png", "a.png"]) else {
            return expect(false, "two outputs should be refused")
        }
    }

    static func testOptionsRefuseAnUnknownFlag() {
        guard case .failure(let error) = options(["Tab.bundle", "--window", "--colour", "red"]) else {
            return expect(false, "an unknown flag should be refused")
        }
        expect(error.description.contains("--colour"), "the error names the flag: \(error.description)")
    }

    static func testOptionsRefuseAFlagWithoutItsValue() {
        guard case .failure(let error) = options(["Tab.bundle", "--png"]) else {
            return expect(false, "--png with no file should be refused")
        }
        expect(error.description.contains("--png"), "the error names the flag: \(error.description)")
    }

    static func testOptionsRefuseABadSize() {
        for size in ["big", "0x10", "10x", "-5x10"] {
            guard case .failure = options(["Tab.bundle", "--window", "--size", size]) else {
                return expect(false, "the size \(size) should be refused")
            }
        }
    }

    // MARK: - Loading

    static func testSessionHandsThePluginItsSettingsAndAFolderUnderTheRoot() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = PluginSettings(values: ["command": .string("/opt/backup")])
        let tab = PreviewSession.load(bundlePath: "/b/Echo.bundle", settings: settings,
                                      source: PreviewOneTabSource(type: PreviewEchoTab.self),
                                      host: makeHost(), dataRoot: root)
        guard case let .loaded(_, loaded) = tab, let plugin = loaded as? PreviewEchoTab else {
            return expect(false, "the echo tab should load: \(tab)")
        }
        expect(plugin.host.settings == settings, "the plugin gets the settings file's values")
        expect(plugin.host.dataDirectory == root.appendingPathComponent("preview-echo", isDirectory: true),
               "the plugin's folder is under the preview's root: \(plugin.host.dataDirectory)")
    }

    static func testSessionKeepsTheLoadersReason() {
        let tab = PreviewSession.load(bundlePath: "/b/Gone.bundle", settings: .empty,
                                      source: PreviewFailingSource(reason: "nothing at /b/Gone.bundle"),
                                      host: makeHost(), dataRoot: temporaryDirectory())
        guard case let .failed(location, reason) = tab else { return expect(false, "a failing source should fail") }
        expect(location == "/b/Gone.bundle" && reason == "nothing at /b/Gone.bundle",
               "the failure keeps the path and the loader's sentence: \(location) \(reason)")
    }

    // MARK: - Drawing

    static func testCollectOnceWaitsForTheUpdateOnMain() {
        let plugin = PreviewEchoTab(host: makeHost(runner: CannedReplies.runner([
            CannedReply(path: "/bin/echo", arguments: ["hi"], output: "canned", error: "", status: 0),
        ])))
        expect(PreviewRenderer.collectOnce(plugin), "collect should finish in time")
        expect(plugin.shown == "canned", "the main-queue update has landed when collectOnce returns: \(plugin.shown)")
    }

    static func testCollectOnceGivesUpAfterItsTimeout() {
        let plugin = PreviewSlowTab(host: makeHost())
        expect(!PreviewRenderer.collectOnce(plugin, timeout: 0.05), "a collect slower than the timeout reports false")
    }

    static func testPictureHasTheRequestedSizeAtTheRendererScale() {
        let plugin = PreviewEchoTab(host: makeHost())
        guard let data = PreviewRenderer.pngData(of: plugin, size: CGSize(width: 120, height: 80)),
              let image = NSBitmapImageRep(data: data) else {
            return expect(false, "the view should draw to a PNG")
        }
        let scale = Int(PreviewRenderer.renderScale)
        expect(image.pixelsWide == 120 * scale && image.pixelsHigh == 80 * scale,
               "the picture is the requested size at scale \(scale): \(image.pixelsWide)x\(image.pixelsHigh)")
    }
}

/// Runs `/bin/echo hi` in collect and shows what came back, so a test can see that collect ran,
/// through which runner, and that the update reached main before the picture was drawn.
final class PreviewEchoTab: TabPlugin {
    static let identifier = "preview-echo"
    @MainActor static var lastMade: PreviewEchoTab?

    let title = "Echo"
    let systemImage = "text.bubble"
    let accent = Color.white
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []
    let host: HostServices
    @MainActor private(set) var shown = "not collected"
    @MainActor private(set) var toldVisible = false

    @MainActor init(host: HostServices) {
        self.host = host
        PreviewEchoTab.lastMade = self
    }

    func collect() {
        let text = host.run(path: "/bin/echo", arguments: ["hi"]).output
        DispatchQueue.main.async { MainActor.assumeIsolated { self.shown = text } }
    }

    @MainActor func visibilityChanged(isVisible: Bool) { toldVisible = isVisible }
    @MainActor func makeView() -> AnyView { AnyView(Text(shown)) }
}

/// A collect that takes longer than a test is willing to wait.
final class PreviewSlowTab: TabPlugin {
    static let identifier = "preview-slow"
    let title = "Slow"
    let systemImage = "tortoise"
    let accent = Color.white
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []

    @MainActor init(host: HostServices) {}
    func collect() { Thread.sleep(forTimeInterval: 0.3) }
    @MainActor func makeView() -> AnyView { AnyView(Text("slow")) }
}

struct PreviewOneTabSource: TabSource {
    let type: TabPlugin.Type
    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type { type }
}

struct PreviewFailingSource: TabSource {
    let reason: String
    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type { throw TabLoadError(description: reason) }
}

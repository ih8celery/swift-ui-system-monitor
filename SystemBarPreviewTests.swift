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
}

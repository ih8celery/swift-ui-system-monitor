# Plugin Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `SystemBar --preview <bundle> (--png <out.png> | --window) [--replies <file>] [--settings <file>] [--size WxH]` shows one plugin outside the menu bar, as a saved picture or in an ordinary window.

**Architecture:** A new `@main` entry point checks for `--preview` before the SwiftUI app starts, so a preview never reads or writes `plugins.json`. `PreviewCommand.prepare` turns arguments into either a finished outcome (exit code and message) or a plugin to open in a window. It loads the bundle through the real `TabCatalog` and `BundleTabSource` (one entry, built in memory), hands it a `HostServices` whose runner is either the real `ProcessRunner.run` or a canned-reply runner, and gives it a throwaway data folder. Picture mode runs `collect()` once on a background queue, waits for the main-queue update, and draws with SwiftUI's `ImageRenderer`.

**Tech Stack:** Swift 5 language mode, SwiftUI, AppKit, `swiftc` via `build.sh`/`test.sh` (no SPM). In-process tests use the repo's `expect(...)` helper.

**Spec:** `docs/one-page/systembar-plugin-preview.md`

**Before running `./test.sh`:** run `mc`; it builds the app and every plugin. If available capacity is `LOW` or `UNKNOWN`, wait.

---

## File map

Create (all under `Sources/Host/Preview/`, one job each):

- `PreviewInput.swift` — `PreviewInputError`, `PreviewExit` exit codes.
- `CannedReplies.swift` — parses the replies file; builds the fake `CommandRunner`.
- `PreviewOptions.swift` — parses the `--preview` command line.
- `PreviewSession.swift` — loads one plugin through `TabCatalog`.
- `PreviewRenderer.swift` — runs `collect()` once and draws the view to PNG.
- `PreviewCommand.swift` — ties the above together into a `PreviewOutcome`.
- `PreviewWindow.swift` — the `--window` mode (checked by hand).
- `Sources/Host/Main.swift` — the new `@main`: preview or the normal app.

Create test file: `SystemBarPreviewTests.swift` (repo root, beside the other test files).

Modify:

- `Sources/Host/PluginConfigParser.swift` — add `parseSettingsFile(_:)`.
- `Sources/Host/App.swift` — `SystemBarApp` loses `@main`.
- `SystemBarPerformanceTests.swift` — call `SystemBarPreviewTests.runAll()`.
- `test.sh` — compile the new test file; add the preview boundary check.
- `README.md`, `CLAUDE.md`, `AGENTS.md` — document the mode.

---

### Task 1: Settings file parsing and the preview test file

**Files:**
- Modify: `Sources/Host/PluginConfigParser.swift` (add one static function next to `parse(_:)`)
- Create: `SystemBarPreviewTests.swift`
- Modify: `SystemBarPerformanceTests.swift` (the `main()` list)
- Modify: `test.sh` (the `swiftc` file list)

- [ ] **Step 1: Create the test file with the first failing tests**

`SystemBarPreviewTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Register the file with the test binary**

In `SystemBarPerformanceTests.swift`, in `main()`, after the line `MainActor.assumeIsolated { SystemBarSchedulerTests.runAll() }`, add:

```swift
        MainActor.assumeIsolated { SystemBarPreviewTests.runAll() }
```

In `test.sh`, in the `swiftc` file list, after `SystemBarSchedulerTests.swift \`, add the line:

```
  SystemBarPreviewTests.swift \
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -20 build/test-output.txt`
Expected: non-zero exit; the compiler says `type 'PluginConfigParser' has no member 'parseSettingsFile'`.

- [ ] **Step 4: Add `parseSettingsFile`**

In `Sources/Host/PluginConfigParser.swift`, directly after the closing brace of `static func parse(_ data: Data) -> Result<PluginConfig, PluginConfigError>`, add:

```swift
    /// A file holding one plugin's settings on its own, as `SystemBar --preview --settings` reads
    /// it: the same object an entry's `"settings"` would hold, checked the same way.
    static func parseSettingsFile(_ data: Data) -> Result<PluginSettings, PluginConfigError> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.malformedJSON(malformedDetail(from: error as NSError, in: data)))
        }
        return parseSettings(object, where: "the settings file")
    }
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -8 build/test-output.txt`
Expected: `exit 0`, and the last line is `Name check passed: ...`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Host/PluginConfigParser.swift SystemBarPreviewTests.swift SystemBarPerformanceTests.swift test.sh
git commit -m "Read a plugin's settings from a file of their own, for the preview"
```

---

### Task 2: Canned replies

**Files:**
- Create: `Sources/Host/Preview/PreviewInput.swift`
- Create: `Sources/Host/Preview/CannedReplies.swift`
- Test: `SystemBarPreviewTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these calls to the end of `runAll()`:

```swift
        testRepliesFileReadsRepliesWithDefaults()
        testRepliesFileRejectsAnUnknownKey()
        testRepliesFileRejectsAnUnknownReplyKey()
        testRepliesFileRejectsANonNumberStatus()
        testRepliesFileRejectsABooleanStatus()
        testRepliesFileRejectsAReplyWithoutPath()
        testCannedRunnerAnswersAnExactMatch()
        testCannedRunnerRefusesAnythingElseWith127()
```

Add these functions inside the struct:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -20 build/test-output.txt`
Expected: non-zero exit; `cannot find 'CannedReplies' in scope`.

- [ ] **Step 3: Write `PreviewInput.swift`**

```swift
import Foundation

/// A problem with what was typed or with a file the preview was pointed at: one sentence a
/// person can act on.
struct PreviewInputError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// What `SystemBar --preview` exits with.
enum PreviewExit {
    static let ok: Int32 = 0
    /// The bundle did not load, or its picture could not be drawn or saved.
    static let failed: Int32 = 1
    /// The command line, the settings file or the replies file was wrong.
    static let badInput: Int32 = 2
}
```

- [ ] **Step 4: Write `CannedReplies.swift`**

```swift
import Foundation
import SystemBarKit

/// One fake answer: when a plugin runs exactly this path with exactly these arguments.
struct CannedReply: Equatable, Sendable {
    let path: String
    let arguments: [String]
    let output: String
    let error: String
    let status: Int32
}

/// The `--replies` file and the runner that answers from it. Parsed as strictly as plugins.json:
/// an unknown key or a wrong type names its place, so a typo never quietly runs a real command.
enum CannedReplies {
    /// What a command with no canned reply exits with: the shell's "command not found".
    static let missingStatus: Int32 = 127

    private static let topLevelKeys: Set<String> = ["replies"]
    private static let replyKeys: Set<String> = ["path", "arguments", "output", "error", "status"]

    static func parse(_ data: Data) -> Result<[CannedReply], PreviewInputError> {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(PreviewInputError(description: "the replies file is not valid JSON"))
        }
        guard let object = root as? [String: Any] else {
            return .failure(PreviewInputError(description: "the replies file must be a JSON object"))
        }
        if let unknown = object.keys.sorted().first(where: { !topLevelKeys.contains($0) }) {
            return .failure(PreviewInputError(description: "the replies file has an unknown key \"\(unknown)\""))
        }
        guard let list = object["replies"] as? [Any] else {
            return .failure(PreviewInputError(description: "the replies file needs \"replies\", a list"))
        }
        var replies: [CannedReply] = []
        for (index, raw) in list.enumerated() {
            switch parseReply(raw, place: "reply \(index + 1)") {
            case .success(let reply): replies.append(reply)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(replies)
    }

    private static func parseReply(_ raw: Any, place: String) -> Result<CannedReply, PreviewInputError> {
        func problem(_ text: String) -> Result<CannedReply, PreviewInputError> {
            .failure(PreviewInputError(description: "\(place) in the replies file \(text)"))
        }
        guard let object = raw as? [String: Any] else { return problem("must be an object") }
        if let unknown = object.keys.sorted().first(where: { !replyKeys.contains($0) }) {
            return problem("has an unknown key \"\(unknown)\"")
        }
        guard let path = object["path"] as? String else { return problem("needs \"path\", a string") }
        guard let arguments = object["arguments"] as? [String] else {
            return problem("needs \"arguments\", a list of strings")
        }
        guard let output = object["output"] as? String else { return problem("needs \"output\", a string") }
        let error = object["error"] ?? ""
        guard let errorText = error as? String else { return problem("has an \"error\" that is not a string") }
        let status = object["status"] ?? NSNumber(value: 0)
        guard !isBoolean(status), let number = status as? NSNumber, number.doubleValue == number.doubleValue.rounded() else {
            return problem("has a \"status\" that is not a whole number")
        }
        return .success(CannedReply(path: path, arguments: arguments, output: output, error: errorText, status: number.int32Value))
    }

    /// JSONSerialization hands back `true` as an NSNumber, so it is told apart by its CF type.
    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// A runner that answers from `replies` and refuses everything else with status 127.
    static func runner(_ replies: [CannedReply]) -> CommandRunner {
        { path, arguments, _, _ in
            if let reply = replies.first(where: { $0.path == path && $0.arguments == arguments }) {
                return CommandOutput(output: reply.output, error: reply.error, status: reply.status, didTimeout: false)
            }
            let line = ([path] + arguments).joined(separator: " ")
            return CommandOutput(output: "", error: "no canned reply for \(line)", status: missingStatus, didTimeout: false)
        }
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -8 build/test-output.txt`
Expected: `exit 0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Host/Preview/PreviewInput.swift Sources/Host/Preview/CannedReplies.swift SystemBarPreviewTests.swift
git commit -m "Preview: answer a plugin's commands from a strict replies file"
```

---

### Task 3: The command line

**Files:**
- Create: `Sources/Host/Preview/PreviewOptions.swift`
- Test: `SystemBarPreviewTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to the end of `runAll()`:

```swift
        testOptionsReadAPictureRunWithEveryFlag()
        testOptionsReadAWindowRunWithTheDefaultSize()
        testOptionsRefuseAMissingBundle()
        testOptionsRefuseNeitherOrBothOutputs()
        testOptionsRefuseAnUnknownFlag()
        testOptionsRefuseAFlagWithoutItsValue()
        testOptionsRefuseABadSize()
```

Add the functions:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -20 build/test-output.txt`
Expected: non-zero exit; `cannot find 'PreviewOptions' in scope`.

- [ ] **Step 3: Write `PreviewOptions.swift`**

```swift
import CoreGraphics
import Foundation

/// What `SystemBar --preview ...` was asked to do. Paths are made absolute here, against the
/// folder the command was run from, because the loader only accepts absolute or `~/` paths.
struct PreviewOptions: Equatable {
    enum Output: Equatable {
        case png(URL)
        case window
    }

    static let flag = "--preview"
    /// The popover's size, so a picture shows the tab as the menu bar would.
    static let defaultSize = CGSize(width: 900, height: 680)
    static let usage = """
    usage: SystemBar --preview <bundle> --png <out.png> [--replies <file>] [--settings <file>] [--size <W>x<H>]
           SystemBar --preview <bundle> --window [--replies <file>] [--settings <file>] [--size <W>x<H>]
    """

    let bundlePath: String
    let output: Output
    let repliesURL: URL?
    let settingsURL: URL?
    let size: CGSize

    private static let valueFlags: Set<String> = ["--png", "--replies", "--settings", "--size"]

    /// `arguments` starts with `--preview`, as `CommandLine.arguments.dropFirst()` does.
    static func parse(_ arguments: [String], currentDirectory: String) -> Result<PreviewOptions, PreviewInputError> {
        var words = Array(arguments.drop(while: { $0 == flag }))
        guard let bundle = words.first, !bundle.hasPrefix("--") else {
            return failure("--preview needs the path of a plugin bundle first")
        }
        words.removeFirst()
        var values: [String: String] = [:]
        var wantsWindow = false
        while let word = words.first {
            words.removeFirst()
            if word == "--window" {
                wantsWindow = true
                continue
            }
            guard valueFlags.contains(word) else { return failure("--preview does not know \(word)") }
            guard values[word] == nil else { return failure("\(word) is given twice") }
            guard let value = words.first, !value.hasPrefix("--") else { return failure("\(word) needs a value") }
            words.removeFirst()
            values[word] = value
        }
        let absolute = { (path: String) in Self.absolutePath(path, currentDirectory: currentDirectory) }
        let output: Output
        switch (values["--png"], wantsWindow) {
        case (let png?, false): output = .png(URL(fileURLWithPath: absolute(png)))
        case (nil, true): output = .window
        case (nil, false): return failure("--preview needs --png <file> or --window")
        case (.some, true): return failure("--preview takes --png or --window, not both")
        }
        var size = defaultSize
        if let text = values["--size"] {
            guard let parsed = parseSize(text) else { return failure("--size must look like 900x680, not \(text)") }
            size = parsed
        }
        return .success(PreviewOptions(
            bundlePath: absolute(bundle),
            output: output,
            repliesURL: values["--replies"].map { URL(fileURLWithPath: absolute($0)) },
            settingsURL: values["--settings"].map { URL(fileURLWithPath: absolute($0)) },
            size: size
        ))
    }

    private static func failure(_ text: String) -> Result<PreviewOptions, PreviewInputError> {
        .failure(PreviewInputError(description: text))
    }

    private static func absolutePath(_ path: String, currentDirectory: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~/") { return path }
        return URL(fileURLWithPath: currentDirectory).appendingPathComponent(path).standardizedFileURL.path
    }

    private static func parseSize(_ text: String) -> CGSize? {
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -8 build/test-output.txt`
Expected: `exit 0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Host/Preview/PreviewOptions.swift SystemBarPreviewTests.swift
git commit -m "Preview: read the --preview command line"
```

---

### Task 4: Loading one plugin

**Files:**
- Create: `Sources/Host/Preview/PreviewSession.swift`
- Test: `SystemBarPreviewTests.swift`

- [ ] **Step 1: Write the test plugin, fake sources and failing tests**

At the bottom of `SystemBarPreviewTests.swift`, outside the struct, add the test plugins and sources. (First run `grep -n "PreviewEchoTab\|PreviewSlowTab\|PreviewOneTabSource\|PreviewFailingSource" *.swift Plugins/*/Tests/*.swift` and expect no matches.)

```swift
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
```

Add to the end of `runAll()`:

```swift
        testSessionHandsThePluginItsSettingsAndAFolderUnderTheRoot()
        testSessionKeepsTheLoadersReason()
```

Add inside the struct:

```swift
    // MARK: - Loading

    static func testSessionHandsThePluginItsSettingsAndAFolderUnderTheRoot() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = PluginSettings(values: ["command": .string("/opt/backup")])
        let tab = PreviewSession.load(bundlePath: "/b/Echo.bundle", settings: settings,
                                      source: PreviewOneTabSource(type: PreviewEchoTab.self),
                                      host: makeHost(), dataRoot: root)
        guard let plugin = tab.plugin as? PreviewEchoTab else { return expect(false, "the echo tab should load: \(tab)") }
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -20 build/test-output.txt`
Expected: non-zero exit; `cannot find 'PreviewSession' in scope`.

- [ ] **Step 3: Write `PreviewSession.swift`**

```swift
import Foundation
import SystemBarKit

/// Loads one bundle exactly as the menu bar would load a `"path"` entry of plugins.json, through
/// the same catalog (and so the same name checks, init timing and per-plugin host), but from a
/// list of one held in memory, so the real plugins.json is never read or written.
enum PreviewSession {
    @MainActor static func load(
        bundlePath: String,
        settings: PluginSettings,
        source: TabSource,
        host: HostServices,
        dataRoot: URL
    ) -> LoadedTab {
        let entry = PluginEntry(name: nil, path: bundlePath, isEnabled: true, settings: settings)
        let tabs = TabCatalog.build(config: PluginConfig(plugins: [entry]), source: source, host: host, dataRoot: dataRoot)
        return tabs[0]
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -8 build/test-output.txt`
Expected: `exit 0`. If `PluginConfig(plugins:)` does not compile, read `struct PluginConfig` in `Sources/Host/PluginConfig.swift` and use its initializer.

- [ ] **Step 5: Commit**

```bash
git add Sources/Host/Preview/PreviewSession.swift SystemBarPreviewTests.swift
git commit -m "Preview: load one bundle through the real catalog, from a list held in memory"
```

---

### Task 5: Collect once and draw a picture

**Files:**
- Create: `Sources/Host/Preview/PreviewRenderer.swift`
- Test: `SystemBarPreviewTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to the end of `runAll()`:

```swift
        testCollectOnceWaitsForTheUpdateOnMain()
        testCollectOnceGivesUpAfterItsTimeout()
        testPictureHasTheRequestedSizeAtTheRendererScale()
```

Add inside the struct:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -20 build/test-output.txt`
Expected: non-zero exit; `cannot find 'PreviewRenderer' in scope`.

- [ ] **Step 3: Write `PreviewRenderer.swift`**

```swift
import AppKit
import Foundation
import SwiftUI
import SystemBarKit

/// Runs a plugin's `collect()` once, the way the scheduler would (off the main thread), waits
/// for what it sends back to main, then draws its view.
@MainActor
enum PreviewRenderer {
    /// Longer than `ProcessRunner.defaultTimeout`, so one slow command cannot cut a collect short.
    static let collectTimeout: TimeInterval = 60
    /// Time after collect for updates a plugin sends to main from its own queues.
    static let settleAfterCollect: TimeInterval = 0.2
    static let renderScale: CGFloat = 2
    private static let pollInterval: TimeInterval = 0.01

    /// True when collect returned within `timeout`. Anything the plugin queued on main during
    /// collect has run by then: the main queue is first in, first out, and the "finished" mark
    /// is queued after collect returns.
    static func collectOnce(_ plugin: TabPlugin, timeout: TimeInterval = collectTimeout) -> Bool {
        let finished = PreviewFlag()
        let box = PreviewPluginBox(plugin: plugin)
        DispatchQueue(label: "systembar.preview.collect").async {
            box.plugin.collect()
            DispatchQueue.main.async { finished.set() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished.isSet && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }
        guard finished.isSet else { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(settleAfterCollect))
        return true
    }

    static func pngData(of plugin: TabPlugin, size: CGSize, scale: CGFloat = renderScale) -> Data? {
        let content = plugin.makeView()
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Tells the plugin it is showing, collects once, draws and saves. Nil on success, or the
    /// sentence saying what went wrong.
    static func writePicture(of plugin: TabPlugin, size: CGSize, to url: URL) -> String? {
        plugin.visibilityChanged(isVisible: true)
        guard collectOnce(plugin) else {
            return "\(type(of: plugin).identifier)'s collect() did not finish within \(Int(collectTimeout)) s"
        }
        guard let data = pngData(of: plugin, size: size) else {
            return "\(type(of: plugin).identifier)'s view could not be drawn"
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return "could not save the picture to \(url.path): \(error.localizedDescription)"
        }
        return nil
    }
}

/// Set once from main, read from main; locked because it is created on main and captured by a
/// closure that runs on the collect queue.
private final class PreviewFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Carries the plugin to its collect queue, as the scheduler does; the SDK promises collect is
/// safe to call off the main thread.
private struct PreviewPluginBox: @unchecked Sendable {
    let plugin: TabPlugin
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -8 build/test-output.txt`
Expected: `exit 0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Host/Preview/PreviewRenderer.swift SystemBarPreviewTests.swift
git commit -m "Preview: collect once off main, wait for the update, and draw the tab to a PNG"
```

---

### Task 6: The preview command

**Files:**
- Create: `Sources/Host/Preview/PreviewCommand.swift`
- Test: `SystemBarPreviewTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to the end of `runAll()`:

```swift
        testCommandSavesAPictureUsingTheRepliesAndSettingsFiles()
        testCommandRefusesBadInputWithUsageAndExit2()
        testCommandRefusesABadRepliesFileWithExit2()
        testCommandReportsALoadFailureLikeListPlugins()
        testCommandHandsAWindowRunBackWithThePlugin()
```

Add inside the struct:

```swift
    // MARK: - Command

    static func prepare(_ words: [String], folder: URL, source: TabSource) -> PreviewOutcome {
        PreviewCommand.prepare(
            arguments: [PreviewOptions.flag] + words,
            currentDirectory: folder.path,
            source: source,
            dataRoot: folder.appendingPathComponent("data", isDirectory: true),
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot())
        )
    }

    static func testCommandSavesAPictureUsingTheRepliesAndSettingsFiles() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try? Data(#"{ "replies": [ { "path": "/bin/echo", "arguments": ["hi"], "output": "from replies" } ] }"#.utf8)
            .write(to: folder.appendingPathComponent("replies.json"))
        try? Data(#"{ "command": "/opt/backup" }"#.utf8).write(to: folder.appendingPathComponent("settings.json"))
        let outcome = prepare(["Echo.bundle", "--png", "echo.png", "--replies", "replies.json",
                               "--settings", "settings.json", "--size", "200x100"],
                              folder: folder, source: PreviewOneTabSource(type: PreviewEchoTab.self))
        guard case let .finished(code, _) = outcome else { return expect(false, "a picture run finishes: \(outcome)") }
        expect(code == PreviewExit.ok, "a picture run exits 0, got \(code)")
        expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("echo.png").path), "the picture is saved")
        guard let plugin = PreviewEchoTab.lastMade else { return expect(false, "the echo tab was made") }
        expect(plugin.shown == "from replies", "collect ran through the canned runner: \(plugin.shown)")
        expect(plugin.toldVisible, "the plugin was told it is showing")
        expect(plugin.host.settings.string(forKey: "command") == "/opt/backup", "the settings file reached the plugin")
    }

    static func testCommandRefusesBadInputWithUsageAndExit2() {
        let outcome = prepare(["--window"], folder: temporaryDirectory(), source: PreviewOneTabSource(type: PreviewEchoTab.self))
        guard case let .finished(code, message) = outcome else { return expect(false, "bad input finishes") }
        expect(code == PreviewExit.badInput, "bad input exits 2, got \(code)")
        expect(message?.contains("usage:") == true, "bad input prints the usage: \(message ?? "nil")")
    }

    static func testCommandRefusesABadRepliesFileWithExit2() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try? Data(#"{ "answers": [] }"#.utf8).write(to: folder.appendingPathComponent("replies.json"))
        let outcome = prepare(["Echo.bundle", "--window", "--replies", "replies.json"], folder: folder,
                              source: PreviewOneTabSource(type: PreviewEchoTab.self))
        guard case let .finished(code, message) = outcome else { return expect(false, "a bad replies file finishes") }
        expect(code == PreviewExit.badInput && message?.contains("\"answers\"") == true,
               "a bad replies file exits 2 naming the key: \(code) \(message ?? "nil")")
    }

    static func testCommandReportsALoadFailureLikeListPlugins() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = folder.appendingPathComponent("Gone.bundle").path
        let outcome = prepare([bundle, "--png", "x.png"], folder: folder,
                              source: PreviewFailingSource(reason: "nothing at \(bundle)"))
        guard case let .finished(code, message) = outcome else { return expect(false, "a load failure finishes") }
        expect(code == PreviewExit.failed, "a load failure exits 1, got \(code)")
        expect(message == "error \(bundle): nothing at \(bundle)", "the same line --list-plugins prints: \(message ?? "nil")")
    }

    static func testCommandHandsAWindowRunBackWithThePlugin() {
        let outcome = prepare(["Echo.bundle", "--window", "--size", "300x200"], folder: temporaryDirectory(),
                              source: PreviewOneTabSource(type: PreviewEchoTab.self))
        guard case let .openWindow(plugin, size) = outcome else { return expect(false, "a window run opens a window: \(outcome)") }
        expect(plugin is PreviewEchoTab && size == CGSize(width: 300, height: 200), "the window gets the plugin and size")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -20 build/test-output.txt`
Expected: non-zero exit; `cannot find 'PreviewCommand' in scope`.

- [ ] **Step 3: Write `PreviewCommand.swift`**

```swift
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
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -8 build/test-output.txt`
Expected: `exit 0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Host/Preview/PreviewCommand.swift SystemBarPreviewTests.swift
git commit -m "Preview: one command from arguments to a saved picture or a plugin for a window"
```

---

### Task 7: The window, the entry point and the boundary check

**Files:**
- Create: `Sources/Host/Preview/PreviewWindow.swift`
- Create: `Sources/Host/Main.swift`
- Modify: `Sources/Host/App.swift:6-7` (remove `@main`)
- Modify: `test.sh` (boundary check after `Boundary check passed`)

- [ ] **Step 1: Write the failing boundary check**

In `test.sh`, directly after the line `echo "Boundary check passed: a bundle built against the shipped SDK loads through the real loader"`, add:

```zsh
# The preview: one bundle outside the menu bar, from the built app, with fake answers, never
# reading or writing plugins.json.
cat > "$tmp/replies.json" <<'JSON'
{ "replies": [ { "path": "/bin/date", "arguments": ["+%H:%M:%S"], "output": "12:34:56\n" } ] }
JSON
SYSTEMBAR_PLUGINS_FILE="$tmp/untouched/plugins.json" ./SystemBar.app/Contents/MacOS/SystemBar \
  --preview "$tmp/HelloTab.bundle" --png "$tmp/hello.png" --replies "$tmp/replies.json" \
  || { echo "Preview check failed: --preview --png exited $?" >&2; exit 1; }
[[ -s "$tmp/hello.png" ]] || { echo "Preview check failed: no picture at $tmp/hello.png" >&2; exit 1; }
[[ ! -e "$tmp/untouched/plugins.json" ]] || { echo "Preview check failed: the preview wrote plugins.json" >&2; exit 1; }

missing_out=$(./SystemBar.app/Contents/MacOS/SystemBar --preview "$tmp/Missing.bundle" --png "$tmp/missing.png" 2>&1) \
  && missing_status=0 || missing_status=$?
if (( missing_status != 1 )) || [[ "$missing_out" != "error $tmp/Missing.bundle: nothing at $tmp/Missing.bundle" ]]; then
  echo "Preview check failed: a missing bundle should exit 1 with the loader's line; got $missing_status: $missing_out" >&2
  exit 1
fi
echo "Preview check passed: a bundle previews to a picture from the built app, and a missing one says why"
```

- [ ] **Step 2: Run it to see it fail**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; tail -5 build/test-output.txt`
Expected: `exit 1` with `Preview check failed: ...` (today `--preview` is ignored and the app starts normally, or the check times out with no picture; if the app hangs, stop it with Ctrl-C — that also counts as the expected failure).

- [ ] **Step 3: Write `PreviewWindow.swift`**

```swift
import AppKit
import SwiftUI
import SystemBarKit

/// `--window`: the tab in an ordinary window, collected on its own timer by the same presenter
/// and scheduler as the menu bar. Closing the window ends the preview.
@MainActor
enum PreviewWindow {
    static func run(plugin: TabPlugin, size: CGSize, presenter: TabPresenter) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(plugin.title) — SystemBar preview"
        window.contentView = NSHostingView(rootView: plugin.makeView())
        let closer = PreviewQuitOnClose()
        window.delegate = closer
        window.center()
        window.makeKeyAndOrderFront(nil)
        presenter.present(plugin: plugin, isVisible: true)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(closer) { app.run() }
        exit(PreviewExit.ok)
    }
}

private final class PreviewQuitOnClose: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        exit(PreviewExit.ok)
    }
}
```

- [ ] **Step 4: Write `Sources/Host/Main.swift`**

```swift
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
```

- [ ] **Step 5: Remove `@main` from the app**

In `Sources/Host/App.swift`, change:

```swift
#if !TESTING
@main
struct SystemBarApp: App {
```

to:

```swift
#if !TESTING
/// Started by `SystemBarMain` when the command line is not a preview.
struct SystemBarApp: App {
```

- [ ] **Step 6: Run everything to see it pass**

Run: `./test.sh > build/test-output.txt 2>&1; echo "exit $?"; grep -E "check (passed|failed)" build/test-output.txt`
Expected: `exit 0`, and the list includes `Preview check passed: ...` and every earlier check.

- [ ] **Step 7: Check the picture and the window by hand**

Run: `open "$(ls -t ${TMPDIR:-/tmp}/tmp.*/hello.png 2>/dev/null | head -1)" 2>/dev/null || echo "test.sh removed its folder; run the next command"`
Then build the example once and preview it in a window:

```bash
./build-plugin.sh Examples/HelloTab build/HelloTab.bundle SystemBar.app
./SystemBar.app/Contents/MacOS/SystemBar --preview build/HelloTab.bundle --window
```

Expected: a window titled `Hello — SystemBar preview` showing `Hello from a plugin. The time is …`, with the time changing every 5 seconds. Closing it ends the command with exit 0. Then check the menu bar app still starts normally: `./SystemBar.app/Contents/MacOS/SystemBar --list-plugins` prints the six tabs.

- [ ] **Step 8: Commit**

```bash
git add Sources/Host/Preview/PreviewWindow.swift Sources/Host/Main.swift Sources/Host/App.swift test.sh
git commit -m "Add SystemBar --preview: one plugin as a picture or in a window, checked from the built app"
```

---

### Task 8: Documentation

**Files:**
- Modify: `README.md` (after the "Writing a plugin" section's paragraph that ends "...and press Relaunch.")
- Modify: `CLAUDE.md`, `AGENTS.md` (Architecture Overview paragraph, identical sentence in both)

- [ ] **Step 1: Add a README section**

Find the "Writing a plugin" section with `grep -n "Writing a plugin" README.md`. After that section's last paragraph, add:

````markdown
### Previewing a plugin without installing it

`SystemBar --preview` shows one plugin outside the menu bar, through the same loader, without
reading or writing `plugins.json`:

```
SystemBar.app/Contents/MacOS/SystemBar --preview MyTab.bundle --png my-tab.png
SystemBar.app/Contents/MacOS/SystemBar --preview MyTab.bundle --window
```

`--png` tells the plugin it is showing, runs `collect()` once, waits for its update, saves a
picture (900×680 points at 2×, or `--size WxH`) and exits. `--window` opens the tab in a
window and refreshes it on its own timer until you close it. `--settings file.json` hands the
plugin the same object a `"settings"` entry would. `--replies file.json` answers the plugin's
commands from a file instead of running them:

```json
{ "replies": [ { "path": "/bin/date", "arguments": ["+%H:%M:%S"], "output": "12:34:56\n" } ] }
```

A reply matches on the exact path and arguments; `error` and `status` are optional. A command
with no reply exits 127 with `no canned reply for <command>`. The plugin's data folder is a
fresh temporary one. Exit codes: 0 done, 1 the bundle did not load or could not be drawn (the
same line `--list-plugins` prints), 2 a wrong argument or file. Pictures are for looking at,
not for comparing pixel by pixel: fonts change with macOS.
````

- [ ] **Step 2: Add one sentence to CLAUDE.md and AGENTS.md**

In both files, at the end of the Architecture Overview paragraph that ends with `` `RootView` renders the loaded list and never names a tab.``, add:

```
`Sources/Host/Main.swift` is the entry point: `SystemBar --preview <bundle>` (`Sources/Host/Preview/`) loads one bundle through `TabCatalog` with an in-memory one-entry list, optional canned command replies and a temporary data folder, and saves a picture or opens a window, without touching `plugins.json`; anything else starts `SystemBarApp`.
```

- [ ] **Step 3: Check the two files still match**

Run: `diff <(sed -n '/## Architecture Overview/,/## Conventions/p' CLAUDE.md) <(sed -n '/## Architecture Overview/,/## Conventions/p' AGENTS.md) && echo same`
Expected: `same`.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md AGENTS.md
git commit -m "Document SystemBar --preview"
```

import Foundation
import SwiftUI
import SystemBarKit

// Helpers and fakes shared by more than one test file. A helper used by only one file lives in
// that file instead.

/// A HostServices with empty feeds, a silent log, and a runner that succeeds with no output
/// unless a test passes its own.
@MainActor
func makeHost(
    processes: Feed<ProcessSummary> = Feed(initial: ProcessSummary()),
    fastStats: Feed<FastStatsSnapshot> = Feed(initial: FastStatsSnapshot()),
    runner: @escaping CommandRunner = { _, _, _, _ in
        CommandOutput(output: "", error: "", status: 0, didTimeout: false)
    },
    log: @escaping @Sendable (String) -> Void = { _ in }
) -> HostServices {
    HostServices(
        homeDirectory: "/tmp/systembar-tests",
        processes: processes,
        fastStats: fastStats,
        runner: runner,
        log: log
    )
}

/// A fresh, empty folder under the system's temporary directory, so no test touches the real
/// Application Support folder. The caller removes it.
func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("systembar-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The smallest possible plugin. Shared by every test that needs a tab.
final class FakeTab: TabPlugin {
    static let identifier = "fake"
    let title = "Fake"
    let systemImage = "questionmark"
    let accent = Color.white
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(Text("fake")) }
}

/// A tab that counts its collects and declares whatever intervals a test gives it, so a test can
/// watch the scheduler's fast and slow cadences, and whether the two ever overlap. `work` is how
/// long each collect sleeps, for the tests that need one still running when the timers swap.
final class BackgroundTab: TabPlugin {
    static let identifier = "background"
    let title = "Background"
    let systemImage = "moon"
    let accent = Color.gray
    let refreshInterval: TimeInterval
    let backgroundInterval: TimeInterval?
    let sharedFeeds: Set<SharedFeed> = []
    private let work: TimeInterval
    private let lock = NSLock()
    private var inFlight = false
    private var collects = 0
    private var didOverlap = false

    convenience init(host: HostServices) {
        self.init(refresh: 5, background: 60)
    }

    init(refresh: TimeInterval, background: TimeInterval?, work: TimeInterval = 0) {
        refreshInterval = refresh
        backgroundInterval = background
        self.work = work
    }

    func collect() {
        lock.withLock {
            if inFlight { didOverlap = true }
            inFlight = true
            collects += 1
        }
        if work > 0 { Thread.sleep(forTimeInterval: work) }
        lock.withLock { inFlight = false }
    }

    @MainActor func makeView() -> AnyView { AnyView(Text("background")) }

    var count: Int { lock.withLock { collects } }
    var overlapped: Bool { lock.withLock { didOverlap } }
}

/// Spins the run loop until `condition` holds or `timeout` elapses, so a test waits only as
/// long as the machine actually needs rather than a fixed guess that either flakes under load
/// or wastes time when the machine is fast.
func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

/// Lets the run loop turn for `seconds`, for the tests that check something did *not* happen.
/// (Not named `pause`: Darwin already has a `pause()`.)
func spinRunLoop(for seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Captures every message it is given, under a lock, because runners and log closures are
/// `@Sendable` and may be called from a plugin's collect queue.
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ message: String) {
        lock.withLock { stored.append(message) }
    }

    var count: Int { lock.withLock { stored.count } }
    var messages: [String] { lock.withLock { stored } }
}

/// A runner that writes each command it is asked to run into `recorder` as "path arg arg" and
/// answers from `answers`, keyed by that same line. Anything not listed fails with status 1, so
/// a test sees an unexpected command rather than an empty success.
func recordingRunner(_ recorder: LogRecorder, answers: [String: String]) -> CommandRunner {
    { path, arguments, _, _ in
        let line = ([path] + arguments).joined(separator: " ")
        recorder.record(line)
        guard let output = answers[line] else {
            return CommandOutput(output: "", error: "unexpected command: \(line)", status: 1, didTimeout: false)
        }
        return CommandOutput(output: output, error: "", status: 0, didTimeout: false)
    }
}

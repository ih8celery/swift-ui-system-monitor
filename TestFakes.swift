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
    runner: @escaping CommandRunner = { _, _, _, _ in
        CommandOutput(output: "", error: "", status: 0, didTimeout: false)
    }
) -> HostServices {
    HostServices(
        homeDirectory: "/tmp/systembar-tests",
        processes: processes,
        fastStats: Feed(initial: FastStatsSnapshot()),
        runner: runner,
        log: { _ in }
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

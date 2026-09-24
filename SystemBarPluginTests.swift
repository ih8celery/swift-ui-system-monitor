import Foundation
import SwiftUI

/// Tests for the plugin model: the contract a tab conforms to, the config file that lists tabs,
/// and the catalog that turns that file into loaded tabs or visible failures.
struct SystemBarPluginTests {
    static func runAll() {
        testPluginIsConstructedThroughItsMetatype()
        testHostServicesForwardsToTheRunner()
    }

    static func makeHost(
        runner: @escaping CommandRunner = { _, _, _, _ in
            CommandOutput(output: "", error: "", status: 0, didTimeout: false)
        }
    ) -> HostServices {
        HostServices(homeDirectory: "/tmp/systembar-tests", runner: runner, log: { _ in })
    }

    // MARK: - Contract

    private static func testPluginIsConstructedThroughItsMetatype() {
        let type: TabPlugin.Type = FakeTab.self
        let plugin = type.init(host: makeHost())
        expect(type.identifier == "fake", "the identifier is read from the metatype, not the instance")
        expect(plugin.title == "Fake", "the instance carries its title")
        _ = plugin.makeView()
        plugin.visibilityChanged(isVisible: true)
        expect(true, "visibilityChanged has a default implementation, so a plugin need not write one")
    }

    private static func testHostServicesForwardsToTheRunner() {
        var seen: (path: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval)?
        let host = makeHost { path, arguments, environment, timeout in
            seen = (path, arguments, environment, timeout)
            return CommandOutput(output: "ran", error: "", status: 0, didTimeout: false)
        }
        let output = host.run(path: "/bin/echo", arguments: ["hi"], environment: ["PATH": "/x"], timeout: 3)
        expect(output.output == "ran", "run returns what the runner returned")
        expect(seen?.path == "/bin/echo" && seen?.arguments == ["hi"], "path and arguments reach the runner unchanged")
        expect(seen?.environment == ["PATH": "/x"] && seen?.timeout == 3, "environment and timeout reach the runner unchanged")
    }
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
    func makeView() -> AnyView { AnyView(Text("fake")) }
}

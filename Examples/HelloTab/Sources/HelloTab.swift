import Foundation
import SwiftUI
import SystemBarKit

/// The smallest tab that loads. Copy this directory to start your own; the README's "Writing a
/// plugin" section walks through it. Two names must be unique to your plugin: the executable
/// name in Info.plist (it is also the Swift module name, so a valid identifier) and the
/// `@objc(...)` class name, because every loaded bundle shares one Objective-C runtime.
///
/// The host builds one of these at launch, calls `collect()` on a queue it owns for this plugin
/// every `refreshInterval` seconds while the tab is showing, and puts `makeView()` in the window.
/// `@objc(HelloTabPlugin)` is the name Info.plist's NSPrincipalClass points at.
@objc(HelloTabPlugin)
public final class HelloTabPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "hello"
    public let title = "Hello"
    public let systemImage = "hand.wave"
    public let accent = Palette.cyan
    public let refreshInterval: TimeInterval = 5
    public let sharedFeeds: Set<SharedFeed> = []

    @Published private(set) var greeting = "Collecting…"
    private let host: HostServices

    /// Main thread, once, at launch.
    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
    }

    /// Not on the main thread. Do the work here, then publish on main: the panel observes
    /// this object from there. Subprocesses go through the host: a path and arguments, no shell.
    public func collect() {
        let result = host.run(path: "/bin/date", arguments: ["+%H:%M:%S"])
        let time = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = result.status == 0 ? "Hello from a plugin. The time is \(time)." : "date failed: \(result.error)"
        DispatchQueue.main.async { [weak self] in
            self?.greeting = text
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(HelloTabView(plugin: self))
    }
}

struct HelloTabView: View {
    @ObservedObject var plugin: HelloTabPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Hello")
            EvidenceRow(label: "Greeting", value: "Live", detail: plugin.greeting)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

import Foundation
import SwiftUI
import SystemBarKit

/// Tests for `HostServices.notify`: what a plugin's test sees, the host's per-rule cooldown,
/// the plugins.json off switch, and that nothing here ever reaches Notification Center.
@MainActor
struct SystemBarNotificationTests {
    static func runAll() {
        testRecordingNotificationsKeepsEveryPostInOrder()
        testTheOriginalInitializersIgnoreNotify()
        testGatePostsOncePerRuleWithinTheCooldown()
        testGateCountsEachRuleSeparately()
        testForPluginNamesTheRuleAfterThePlugin()
        testForPluginWithNotificationsOffPostsNothing()
        testCatalogAppliesTheOffSwitchToEveryPlugin()
    }

    private static func notification(_ id: String) -> PluginNotification {
        PluginNotification(id: id, title: "Title \(id)", body: "Body \(id)")
    }

    private static func host(notify: @escaping @Sendable (PluginNotification) -> Void) -> HostServices {
        HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: { _, _, _, _ in CommandOutput(output: "", error: "", status: 0, didTimeout: false) },
            log: { _ in },
            settings: .empty,
            dataDirectory: testDataRoot,
            notify: notify
        )
    }

    private static func testRecordingNotificationsKeepsEveryPostInOrder() {
        let (notify, posted) = HostServices.recordingNotifications()
        let host = host(notify: notify)
        host.notify(id: "low", title: "Title low", body: "Body low")
        host.notify(id: "low", title: "Title low", body: "Body low")
        host.notify(id: "hot", title: "Title hot", body: "Body hot")
        expect(posted() == [notification("low"), notification("low"), notification("hot")],
               "a test sees every post the plugin asked for, in order, got \(posted())")
    }

    private static func testTheOriginalInitializersIgnoreNotify() {
        // makeHost uses the initializer from before notify existed; posting through it is a no-op.
        makeHost().notify(id: "low", title: "t", body: "b")
    }

    private static func testGatePostsOncePerRuleWithinTheCooldown() {
        let clock = FakeClock()
        let (deliver, delivered) = HostServices.recordingNotifications()
        let gate = NotificationGate(cooldown: 3600, now: clock.now, deliver: deliver)

        gate.post(notification("disk/low"))
        clock.advance(by: 3599)
        gate.post(notification("disk/low"))
        expect(delivered() == [notification("disk/low")], "a repeat inside the cooldown is dropped, got \(delivered())")

        clock.advance(by: 1)
        gate.post(notification("disk/low"))
        expect(delivered().count == 2, "the same rule posts again once the cooldown has passed, got \(delivered())")
    }

    private static func testGateCountsEachRuleSeparately() {
        let (deliver, delivered) = HostServices.recordingNotifications()
        let gate = NotificationGate(cooldown: 3600, now: FakeClock().now, deliver: deliver)
        gate.post(notification("disk/low"))
        gate.post(notification("power/low"))
        expect(delivered().map(\.id) == ["disk/low", "power/low"], "one rule's cooldown never holds back another's, got \(delivered())")
        expect(NotificationGate.standardCooldown == 3600, "the shipped cooldown is an hour per rule, as the handoff says")
    }

    private static func testForPluginNamesTheRuleAfterThePlugin() {
        let (notify, posted) = HostServices.recordingNotifications()
        let plugin = host(notify: notify).forPlugin(identifier: "disk", settings: .empty, dataRoot: testDataRoot, notificationsEnabled: true)
        plugin.notify(id: "low", title: "Title low", body: "Body low")
        expect(posted() == [PluginNotification(id: "disk/low", title: "Title low", body: "Body low")],
               "the host keys a rule by plugin, so two plugins' \"low\" never share a cooldown, got \(posted())")
    }

    private static func testForPluginWithNotificationsOffPostsNothing() {
        let (notify, posted) = HostServices.recordingNotifications()
        let plugin = host(notify: notify).forPlugin(identifier: "disk", settings: .empty, dataRoot: testDataRoot, notificationsEnabled: false)
        plugin.notify(id: "low", title: "t", body: "b")
        expect(posted().isEmpty, "with the off switch set nothing reaches the host, got \(posted())")
    }

    private static func testCatalogAppliesTheOffSwitchToEveryPlugin() {
        let source = MapTabSource(types: ["notifier": NotifyingTab.self])
        let entry = PluginEntry(name: "notifier", path: nil, isEnabled: true)

        let (onNotify, onPosted) = HostServices.recordingNotifications()
        _ = TabCatalog.build(config: PluginConfig(plugins: [entry]), source: source, host: host(notify: onNotify), dataRoot: testDataRoot)
        expect(onPosted().map(\.id) == ["notifier/hello"], "a loaded plugin's notify reaches the host by default, got \(onPosted())")

        let (offNotify, offPosted) = HostServices.recordingNotifications()
        let off = PluginConfig(plugins: [entry], notificationsEnabled: false)
        _ = TabCatalog.build(config: off, source: source, host: host(notify: offNotify), dataRoot: testDataRoot)
        expect(offPosted().isEmpty, "\"notifications\": false in plugins.json silences every plugin, got \(offPosted())")
    }
}

/// A clock a test moves by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { current } }
    }
}

/// Posts one notification as it is constructed, as a rule that fires at once would.
final class NotifyingTab: TabPlugin {
    static let identifier = "notifier"
    let title = "Notifier"
    let systemImage = "bell"
    let accent = Color.orange
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []

    init(host: HostServices) {
        host.notify(id: "hello", title: "Hello", body: "From a test")
    }

    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(Text("notifier")) }
}

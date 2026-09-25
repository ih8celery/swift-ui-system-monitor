import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// Tests for what runs a tab once it is loaded: the feeds it reads, the scheduler that calls
/// its collect(), and the sampling plan.
@MainActor
struct SystemBarSchedulerTests {
    static func runAll() {
        testFeedHoldsTheLatestValueAndPublishesTheNext()
        testHostServicesCarriesTheFeedsItWasBuiltWith()
        testSchedulerCollectsOnlyWhileVisibleAndNeverOverlaps()
        testSchedulerCollectsAtOnceWhenATabAppears()
        testSchedulerStopsThePreviousPluginWhenAnotherIsShown()
        testSchedulerNeverOverlapsACollectInterruptedByHideAndShow()
        testSchedulerClampsABadRefreshInterval()
        testSamplingPlanAddsTheProcessesJobForAPluginThatDeclaresIt()
    }

    /// Spins the run loop until `condition` holds or `timeout` elapses, so a scheduler test
    /// waits only as long as the machine actually needs rather than a fixed guess that either
    /// flakes under load or wastes time when the machine is fast.
    private static func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Feed

    private static func testFeedHoldsTheLatestValueAndPublishesTheNext() {
        let feed = Feed(initial: 1)
        var received: [(value: Int, wasOnMain: Bool)] = []
        let subscription = feed.publisher.sink { value in
            received.append((value, Thread.isMainThread))
        }
        // Both sends come from one async block, so their order is fixed; two separate blocks
        // could be scheduled onto the global queue in either order.
        DispatchQueue.global().async {
            feed.send(2)
            feed.send(3)
        }
        let deadline = Date().addingTimeInterval(2)
        while received.count < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(received.map(\.value) == [2, 3], "the publisher delivers every reading after subscription, in order, got \(received.map(\.value))")
        expect(received.allSatisfy(\.wasOnMain), "every delivery lands on the main thread")
        expect(feed.value == 3, "value is the latest reading, got \(feed.value)")
        subscription.cancel()
    }

    private static func testHostServicesCarriesTheFeedsItWasBuiltWith() {
        let feed = Feed(initial: ProcessSummary())
        let host = HostServices(
            homeDirectory: "/tmp",
            processes: feed,
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: ProcessRunner.run,
            log: { _ in }
        )
        expect(host.processes.value.totalCount == 0, "the feed a host is built with is the one plugins read")
        expect(host.fastStats.value.cpuUsagePercent == 0, "the 1-second feed is there too, starting empty")
        feed.send(ProcessSummary(rows: [ProcessSnapshot(name: "x", count: 1, physical: 1, virtualSize: 1, cpu: 1)], limit: 1))
        expect(host.processes.value.totalCount == 1, "a reading sent to the feed is visible through the host")
    }

    // MARK: - Scheduler

    /// A scheduler for the timing tests: a minimum far below any fake's declared interval, so
    /// none of them are clamped, and a silent log, so a run of test.sh never prints a clamp line.
    private static func makeTestScheduler() -> PluginScheduler {
        PluginScheduler(minimumRefreshInterval: 0.01, log: { _ in })
    }

    private static func testSchedulerCollectsOnlyWhileVisibleAndNeverOverlaps() {
        let plugin = TickingTab(host: makeHost())
        let scheduler = makeTestScheduler()
        scheduler.show(plugin)
        waitUntil { plugin.count >= 3 }
        let whileVisible = plugin.count
        expect(whileVisible >= 3, "a visible tab is collected every refreshInterval, got \(whileVisible) collects at 0.05s")
        expect(!plugin.overlapped, "collect never runs concurrently with itself")
        scheduler.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let afterHiding = plugin.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(plugin.count == afterHiding, "a hidden tab is not collected, got \(plugin.count - afterHiding) more collects")
    }

    private static func testSchedulerCollectsAtOnceWhenATabAppears() {
        let plugin = TickingTab(host: makeHost())
        let scheduler = makeTestScheduler()
        scheduler.show(plugin)
        waitUntil { plugin.count >= 1 }
        expect(plugin.count >= 1, "showing a tab collects immediately, not after the first interval")
        scheduler.hide()
    }

    private static func testSchedulerStopsThePreviousPluginWhenAnotherIsShown() {
        let a = TickingTab(host: makeHost())
        let b = TickingTab(host: makeHost())
        let scheduler = makeTestScheduler()
        scheduler.show(a)
        waitUntil { a.count >= 1 }
        scheduler.show(b)
        let aCountAtSwitch = a.count
        waitUntil { b.count >= 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(a.count == aCountAtSwitch, "showing another tab stops the previous one's timer, got \(a.count - aCountAtSwitch) more collects on the old tab")
        expect(b.count >= 1, "the newly shown tab is collected")
        scheduler.hide()
    }

    private static func testSchedulerNeverOverlapsACollectInterruptedByHideAndShow() {
        let plugin = SlowTickingTab(host: makeHost())
        let scheduler = makeTestScheduler()
        scheduler.show(plugin)
        waitUntil { plugin.count >= 1 }
        scheduler.hide()
        scheduler.show(plugin)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        expect(!plugin.overlapped, "a collect interrupted by hide, then resumed by show, must not overlap the next one")
        scheduler.hide()
    }

    private static func testSchedulerClampsABadRefreshInterval() {
        let log = LogRecorder()
        let scheduler = PluginScheduler(log: { log.record($0) })
        for tooShort in [0, -1, .nan, 0.1] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveInterval(tooShort, identifier: "test")
            expect(effective == MonitorSamplingPlan.minimumRefreshInterval,
                   "a refreshInterval of \(tooShort) must be clamped to the minimum, got \(effective)")
            expect(log.count == before + 1, "clamping a refreshInterval of \(tooShort) must log exactly once, got \(log.count - before) messages")
        }
        for tooLong in [.infinity, 1e12, 86_401] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveInterval(tooLong, identifier: "test")
            expect(effective == MonitorSamplingPlan.maximumRefreshInterval,
                   "a refreshInterval of \(tooLong) must be clamped to the maximum, got \(effective)")
            expect(log.count == before + 1, "clamping a refreshInterval of \(tooLong) must log exactly once, got \(log.count - before) messages")
        }
        for ok in [5, 60, 86_400] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveInterval(ok, identifier: "test")
            expect(effective == ok, "a sane refreshInterval of \(ok) must pass through unchanged")
            expect(log.count == before, "a sane refreshInterval of \(ok) must not log a clamp, got \(log.count - before) messages")
        }
    }

    private static func testSamplingPlanAddsTheProcessesJobForAPluginThatDeclaresIt() {
        expect(MonitorSamplingPlan.jobs(isVisible: true, mode: nil, feeds: [.processes]) == [.processes], "a bundle tab that wants the process feed runs only that sampler")
        expect(MonitorSamplingPlan.jobs(isVisible: true, mode: nil, feeds: []).isEmpty, "a bundle tab that wants nothing runs nothing")
        expect(MonitorSamplingPlan.jobs(isVisible: false, mode: nil, feeds: [.processes]).isEmpty, "hidden means nothing runs, whatever is declared")
        expect(MonitorSamplingPlan.jobs(isVisible: true, mode: .disk, feeds: [.processes]) == [.disk, .processes], "a compiled-in tab's plan and its declared feeds add up")
    }
}

/// Captures every message a scheduler's log closure was given, under a lock, mirroring `Recorder`.
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ message: String) {
        lock.withLock { messages.append(message) }
    }

    var count: Int { lock.withLock { messages.count } }
}

/// Counts collects and checks none overlap, with an interval short enough to observe.
final class TickingTab: TabPlugin {
    static let identifier = "ticking"
    let title = "Ticking"
    let systemImage = "metronome"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 0.05
    let sharedFeeds: Set<SharedFeed> = []
    private let lock = NSLock()
    private var inFlight = false
    private(set) var collects = 0
    private(set) var overlapped = false

    init(host: HostServices) {}

    func collect() {
        lock.withLock {
            if inFlight { overlapped = true }
            inFlight = true
            collects += 1
        }
        Thread.sleep(forTimeInterval: 0.02)
        lock.withLock { inFlight = false }
    }

    var count: Int { lock.withLock { collects } }
    @MainActor func makeView() -> AnyView { AnyView(Text("ticking")) }
}

/// Like `TickingTab` but with a `collect()` long enough to still be running when `hide()`
/// cancels its timer mid-tick — the case that stresses whether a queue interrupted by
/// hide-then-show still serializes rather than overlapping the resumed collect.
final class SlowTickingTab: TabPlugin {
    static let identifier = "slow-ticking"
    let title = "Slow Ticking"
    let systemImage = "hare"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 0.05
    let sharedFeeds: Set<SharedFeed> = []
    private let lock = NSLock()
    private var inFlight = false
    private(set) var collects = 0
    private(set) var overlapped = false

    init(host: HostServices) {}

    func collect() {
        lock.withLock {
            if inFlight { overlapped = true }
            inFlight = true
            collects += 1
        }
        Thread.sleep(forTimeInterval: 0.1)
        lock.withLock { inFlight = false }
    }

    var count: Int { lock.withLock { collects } }
    @MainActor func makeView() -> AnyView { AnyView(Text("slow-ticking")) }
}

import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// Tests for what runs a tab once it is loaded: the feeds it reads, the scheduler that calls
/// its collect(), the host's two shared samplers, and the presenter that tells them what is showing.
@MainActor
struct SystemBarSchedulerTests {
    static func runAll() {
        testFeedHoldsTheLatestValueAndPublishesTheNext()
        testFeedForTestingWritesTheFeedItMade()
        testHostServicesCarriesTheFeedsItWasBuiltWith()
        testSchedulerCollectsOnlyWhileVisibleAndNeverOverlaps()
        testSchedulerCollectsAtOnceWhenATabAppears()
        testSchedulerStopsThePreviousPluginWhenAnotherIsShown()
        testSchedulerNeverOverlapsACollectInterruptedByHideAndShow()
        testSchedulerClampsABadRefreshInterval()
        testSchedulerCollectsAHiddenTabAtItsBackgroundInterval()
        testSchedulerLeavesAHiddenTabAloneWhenItDeclaresNoBackgroundInterval()
        testSchedulerSwapsToTheFastTimerWhenShownAndBackWhenHidden()
        testSchedulerReturnsAReplacedTabToItsBackgroundCadence()
        testSchedulerNeverOverlapsABackgroundCollectWithTheFirstForegroundTick()
        testSchedulerClampsABadBackgroundInterval()
        testSchedulerSettlesBackgroundTimersAfterAWake()
        testSchedulerLeavesTheShownTabAloneAfterAWake()
        testSchedulerStartLeavesAShownTabOnItsFastTimer()
        testSamplersWantOnlyTheFastSamplerWhileTheWindowIsClosed()
        testSamplersKeepTheFastSamplerWhileTheWindowIsClosed()
        testSamplersRunTheFastSamplerForEveryVisibleTab()
        testSamplersRunTheProcessSamplerOnlyWhileATabDeclaresIt()
        testSamplersSampleAtOnceWhenStartedAndKeepTheirRhythm()
        testSamplersFillTheFeeds()
        testSamplersRunNoPsWhenClosedBeforeItsFirstReadingRuns()
        testSamplersStillSampleAfterAQuickCloseAndReopen()
        testFastStatsSamplerTurnsCountersIntoRates()
        testFastStatsSamplerKeepsNinetySeconds()
        testFastStatsSamplerReportsPerCoreAndUserSystemShares()
        testFastStatsSamplerDoesNotSpikeAfterALongGap()
        testFastStatsSamplerCarriesTotalsSinceBoot()
        testNetworkCountersKeepOnlyPhysicalInterfaces()
        testNetworkRateIsRightAcrossThe32BitBoundary()
        testVPNTrafficCountsOnce()
        testAnInterfaceComingOrGoingIsNoSpike()
        testInterfaceCountersAgreeWithNetstat()
        testProcessSamplerGroupsRowsAndDropsTinyOnes()
        testProcessSamplerUsesTheFootprintOnlyForShownGroups()
        testProcessSamplerRunsPsThroughTheRunner()
        testPresenterRunsOnlyTheFastSamplerWhileTheWindowIsClosed()
        testPresenterSwitchRunsOnlyTheShownTabsSamplers()
        testPresenterPausesEverythingForAnErrorTab()
        testPresenterStopsTheTabAndPsWhenTheWindowCloses()
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

    private static func testFeedForTestingWritesTheFeedItMade() {
        let (feed, send) = Feed.forTesting(initial: 1)
        expect(feed.value == 1, "the new feed holds the initial value, got \(feed.value)")

        var received: [(value: Int, wasOnMain: Bool)] = []
        let subscription = feed.publisher.sink { value in
            received.append((value, Thread.isMainThread))
        }
        DispatchQueue.global().async { send(2) }
        let deadline = Date().addingTimeInterval(2)
        while received.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(received.map(\.value) == [2], "the closure's reading reaches a subscriber, got \(received.map(\.value))")
        expect(received.allSatisfy(\.wasOnMain), "and lands on the main thread")
        expect(feed.value == 2, "the closure's reading becomes value, got \(feed.value)")
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
        feed.send(ProcessSummary(rows: [ProcessSnapshot(name: "x", count: 1, physical: 1, virtualSize: 1, cpu: 1)], memoryLimit: 1, cpuLimit: 1))
        expect(host.processes.value.totalCount == 1, "a reading sent to the feed is visible through the host")
    }

    // MARK: - Scheduler

    /// A scheduler for the timing tests: a minimum far below any fake's declared interval, so
    /// none of them are clamped, and a silent log, so a run of test.sh never prints a clamp line.
    private static func makeTestScheduler() -> PluginScheduler {
        PluginScheduler(minimumRefreshInterval: 0.01, wakeNotifications: NotificationCenter(), log: { _ in })
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
        let scheduler = PluginScheduler(wakeNotifications: NotificationCenter(), log: { log.record($0) })
        for tooShort in [0, -1, .nan, 0.1] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveInterval(tooShort, identifier: "test")
            expect(effective == PluginScheduler.minimumRefreshInterval,
                   "a refreshInterval of \(tooShort) must be clamped to the minimum, got \(effective)")
            expect(log.count == before + 1, "clamping a refreshInterval of \(tooShort) must log exactly once, got \(log.count - before) messages")
        }
        for tooLong in [.infinity, 1e12, 86_401] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveInterval(tooLong, identifier: "test")
            expect(effective == PluginScheduler.maximumRefreshInterval,
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

    // MARK: - Background sampling

    /// A scheduler whose floors are short enough that a test's intervals run as declared.
    private static func makeBackgroundScheduler(log: @escaping (String) -> Void = { _ in }) -> PluginScheduler {
        PluginScheduler(
            minimumRefreshInterval: 0.01,
            minimumBackgroundInterval: 0.01,
            settleAfterWake: 0.3,
            wakeNotifications: NotificationCenter(),
            log: log
        )
    }

    private static func testSchedulerCollectsAHiddenTabAtItsBackgroundInterval() {
        let plugin = BackgroundTab(refresh: 0.05, background: 0.1)
        let scheduler = makeBackgroundScheduler()
        scheduler.start([plugin])
        expect(plugin.count == 0, "a background timer's first tick comes one interval after launch, not at once, got \(plugin.count)")
        waitUntil(2) { plugin.count >= 3 }
        expect(plugin.count >= 3, "a hidden tab with a backgroundInterval is collected every interval, got \(plugin.count) collects")
        expect(!plugin.overlapped, "background collects never run concurrently with themselves")
        withExtendedLifetime(scheduler) {}
    }

    private static func testSchedulerLeavesAHiddenTabAloneWhenItDeclaresNoBackgroundInterval() {
        let plugin = BackgroundTab(refresh: 0.05, background: nil)
        let scheduler = makeBackgroundScheduler()
        scheduler.start([plugin])
        spinRunLoop(for: 0.3)
        expect(plugin.count == 0, "a tab with no backgroundInterval is never collected while hidden, got \(plugin.count)")
    }

    private static func testSchedulerSwapsToTheFastTimerWhenShownAndBackWhenHidden() {
        let plugin = BackgroundTab(refresh: 0.02, background: 0.3)
        let scheduler = makeBackgroundScheduler()
        scheduler.start([plugin])
        scheduler.show(plugin)
        waitUntil { plugin.count >= 5 }
        expect(plugin.count >= 5, "showing a background tab collects it at its refreshInterval, got \(plugin.count)")
        scheduler.hide()
        let atHide = plugin.count
        spinRunLoop(for: 0.15)
        // A fast tick already dispatched when hide() cancelled its timer may still land, so
        // allow one; two would mean the slow timer fired early.
        expect(plugin.count <= atHide + 1, "after hide, the next tick waits one background interval, got \(plugin.count - atHide) collects in half an interval")
        waitUntil(2) { plugin.count > atHide }
        expect(plugin.count > atHide, "after hide, the tab goes back to its background cadence")
        expect(!plugin.overlapped, "the fast and slow timers never overlap")
        scheduler.hide()
    }

    private static func testSchedulerReturnsAReplacedTabToItsBackgroundCadence() {
        let background = BackgroundTab(refresh: 0.02, background: 0.1)
        let other = TickingTab(host: makeHost())
        let scheduler = makeBackgroundScheduler()
        scheduler.start([background])
        scheduler.show(background)
        waitUntil { background.count >= 2 }
        scheduler.show(other)
        let atSwitch = background.count
        waitUntil(2) { background.count >= atSwitch + 2 }
        expect(background.count >= atSwitch + 2, "a tab replaced by another returns to its background cadence, got \(background.count - atSwitch) more collects")
        expect(!background.overlapped, "swapping timers never overlaps a collect")
        scheduler.hide()
    }

    private static func testSchedulerNeverOverlapsABackgroundCollectWithTheFirstForegroundTick() {
        let plugin = BackgroundTab(refresh: 0.02, background: 0.05, work: 0.15)
        let scheduler = makeBackgroundScheduler()
        scheduler.start([plugin])
        waitUntil { plugin.count >= 1 }
        // The background collect is now asleep inside `work`; showing the tab must queue the
        // first fast tick behind it, not beside it.
        scheduler.show(plugin)
        spinRunLoop(for: 0.3)
        expect(!plugin.overlapped, "a background collect still running when the tab is shown must finish before the first foreground tick")
        scheduler.hide()
    }

    private static func testSchedulerClampsABadBackgroundInterval() {
        let log = LogRecorder()
        let scheduler = PluginScheduler(wakeNotifications: NotificationCenter(), log: { log.record($0) })
        for tooShort in [0, -1, .nan, 1, 4.9] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveBackgroundInterval(tooShort, identifier: "test")
            expect(effective == PluginScheduler.minimumBackgroundInterval,
                   "a backgroundInterval of \(tooShort) must be clamped to 5 seconds, got \(effective)")
            expect(log.count == before + 1, "clamping a backgroundInterval of \(tooShort) must log exactly once, got \(log.count - before) messages")
            expect((log.messages.last ?? "").contains("backgroundInterval"), "the clamp log names backgroundInterval, got: \(log.messages.last ?? "")")
        }
        for tooLong in [.infinity, 1e12, 86_401] as [TimeInterval] {
            let effective = scheduler.effectiveBackgroundInterval(tooLong, identifier: "test")
            expect(effective == PluginScheduler.maximumRefreshInterval,
                   "a backgroundInterval of \(tooLong) must be clamped to one day, got \(effective)")
        }
        for ok in [5, 60, 900, 86_400] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveBackgroundInterval(ok, identifier: "test")
            expect(effective == ok, "a sane backgroundInterval of \(ok) must pass through unchanged")
            expect(log.count == before, "a sane backgroundInterval of \(ok) must not log, got \(log.count - before) messages")
        }
        expect(PluginScheduler.reportedBackgroundInterval(1) == 5, "the reported cadence is the clamped one, got \(PluginScheduler.reportedBackgroundInterval(1))")
        expect(PluginScheduler.reportedBackgroundInterval(60) == 60, "a sane cadence is reported as declared")
        expect(PluginScheduler.minimumBackgroundInterval == 5, "the background floor the README documents is 5 seconds")
        expect(PluginScheduler.backgroundSettleAfterWake == 120, "the settle the README documents is 120 seconds")
    }

    private static func testSchedulerSettlesBackgroundTimersAfterAWake() {
        let center = NotificationCenter()
        let plugin = BackgroundTab(refresh: 0.02, background: 0.05)
        let scheduler = PluginScheduler(
            minimumRefreshInterval: 0.01,
            minimumBackgroundInterval: 0.01,
            settleAfterWake: 0.3,
            wakeNotifications: center,
            log: { _ in }
        )
        scheduler.start([plugin])
        waitUntil { plugin.count >= 2 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        spinRunLoop(for: 0.02)
        let atWake = plugin.count
        spinRunLoop(for: 0.15)
        // One tick may have been dispatched before the restart cancelled the old timer.
        expect(plugin.count <= atWake + 1, "after a wake, no background tick runs until the settle passes, got \(plugin.count - atWake) in half the settle")
        let midSettle = plugin.count
        waitUntil(2) { plugin.count > midSettle }
        expect(plugin.count > midSettle, "after the settle, the background cadence resumes")

        // The screens waking is the other signal the real app hears.
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        spinRunLoop(for: 0.02)
        let beforeScreens = plugin.count
        spinRunLoop(for: 0.15)
        expect(plugin.count <= beforeScreens + 1, "screensDidWake also restarts the timer with a settle, got \(plugin.count - beforeScreens) ticks in half the settle")
        withExtendedLifetime(scheduler) {}
    }

    private static func testSchedulerLeavesTheShownTabAloneAfterAWake() {
        let center = NotificationCenter()
        let shownTab = BackgroundTab(refresh: 0.02, background: 0.05)
        let hiddenTab = BackgroundTab(refresh: 0.02, background: 0.05)
        // A settle longer than any wait below: if the wake wrongly touched the shown tab, its
        // fast ticks would stop for the rest of the test.
        let scheduler = PluginScheduler(
            minimumRefreshInterval: 0.01,
            minimumBackgroundInterval: 0.01,
            settleAfterWake: 5,
            wakeNotifications: center,
            log: { _ in }
        )
        scheduler.start([shownTab, hiddenTab])
        scheduler.show(shownTab)
        waitUntil { shownTab.count >= 2 && hiddenTab.count >= 2 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        spinRunLoop(for: 0.02)
        let shownAtWake = shownTab.count
        let hiddenAtWake = hiddenTab.count
        waitUntil { shownTab.count >= shownAtWake + 3 }
        expect(shownTab.count >= shownAtWake + 3, "a wake does not touch the shown tab's fast timer, got \(shownTab.count - shownAtWake) ticks")
        expect(hiddenTab.count <= hiddenAtWake + 1, "the same wake did settle the hidden tab, got \(hiddenTab.count - hiddenAtWake) ticks")
        scheduler.hide()
    }

    private static func testSchedulerStartLeavesAShownTabOnItsFastTimer() {
        let plugin = BackgroundTab(refresh: 0.02, background: 5)
        let scheduler = makeBackgroundScheduler()
        scheduler.show(plugin)
        waitUntil { plugin.count >= 2 }
        // Calling start after show (any launch order) must not swap the fast timer for the slow one.
        scheduler.start([plugin])
        let atStart = plugin.count
        waitUntil { plugin.count >= atStart + 3 }
        expect(plugin.count >= atStart + 3, "start must leave an already shown tab on its fast timer, got \(plugin.count - atStart) ticks")
        scheduler.hide()
    }

    // MARK: - Host samplers

    /// Samplers whose collectors only count calls and hand back fixed readings, with intervals
    /// short enough to watch several ticks in a fraction of a second.
    private static func makeTestSamplers(
        fast: CallCounter,
        processes: CallCounter,
        processFeed: Feed<ProcessSummary> = Feed(initial: ProcessSummary()),
        fastFeed: Feed<FastStatsSnapshot> = Feed(initial: FastStatsSnapshot()),
        fastReading: FastStatsSnapshot = FastStatsSnapshot(),
        processReading: ProcessSummary = ProcessSummary(),
        interval: TimeInterval = 0.05,
        fastQueue: DispatchQueue = DispatchQueue(label: "test.samplers.fast"),
        processQueue: DispatchQueue = DispatchQueue(label: "test.samplers.processes")
    ) -> HostSamplers {
        HostSamplers(
            processes: processFeed,
            fastStats: fastFeed,
            sampleFast: { fast.increment(); return fastReading },
            sampleProcesses: { processes.increment(); return processReading },
            fastInterval: interval,
            processInterval: interval,
            fastQueue: fastQueue,
            processQueue: processQueue
        )
    }

    /// Two sampler queues that start suspended, so a test can open and close the window before
    /// either queue runs anything, then resume them and see what was left to run.
    private static func makeHeldQueues() -> (fast: DispatchQueue, processes: DispatchQueue) {
        let fast = DispatchQueue(label: "test.samplers.held.fast")
        let processes = DispatchQueue(label: "test.samplers.held.processes")
        fast.suspend()
        processes.suspend()
        return (fast, processes)
    }

    private static func testSamplersWantOnlyTheFastSamplerWhileTheWindowIsClosed() {
        expect(HostSamplers.wanted(isVisible: false, feeds: [.processes, .fastStats]) == [.fastStats], "a closed window still wants the 1-second sampler, so the histories are full when it opens, but never ps")
        expect(HostSamplers.wanted(isVisible: true, feeds: []) == [.fastStats], "an open window always wants the 1-second sampler, so the histories have no gaps")
        expect(HostSamplers.wanted(isVisible: true, feeds: [.processes]) == [.fastStats, .processes], "a tab that declares the process feed adds the process sampler")
    }

    private static func testSamplersKeepTheFastSamplerWhileTheWindowIsClosed() {
        let fast = CallCounter()
        let processes = CallCounter()
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        samplers.update(isVisible: false, feeds: [.processes, .fastStats])
        waitUntil { fast.count >= 3 }
        expect(fast.count >= 3, "the 1-second sampler ticks with the window closed, got \(fast.count)")
        expect(processes.count == 0, "but ps never runs while it is closed, got \(processes.count)")
        expect(samplers.running == [.fastStats], "and only the 1-second sampler is running, got \(samplers.running)")
        samplers.stopAll()
        expect(samplers.running.isEmpty, "stopAll stops both, got \(samplers.running)")

        let launched = makeTestSamplers(fast: CallCounter(), processes: CallCounter())
        launched.start()
        expect(launched.running == [.fastStats], "the app's launch start runs the 1-second sampler before any window opens, got \(launched.running)")
        launched.stopAll()
    }

    private static func testSamplersRunTheFastSamplerForEveryVisibleTab() {
        let fast = CallCounter()
        let processes = CallCounter()
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        samplers.update(isVisible: true, feeds: [])
        waitUntil { fast.count >= 3 }
        expect(fast.count >= 3, "the 1-second sampler ticks for a tab that declares nothing, got \(fast.count)")
        expect(processes.count == 0, "but ps never runs for it, got \(processes.count)")
        samplers.stopAll()
    }

    private static func testSamplersRunTheProcessSamplerOnlyWhileATabDeclaresIt() {
        let fast = CallCounter()
        let processes = CallCounter()
        let samplers = makeTestSamplers(fast: fast, processes: processes)

        samplers.update(isVisible: true, feeds: [.processes])
        waitUntil { processes.count >= 2 }
        expect(processes.count >= 2, "the process sampler ticks while the tab declares .processes, got \(processes.count)")

        samplers.update(isVisible: true, feeds: [])
        let afterSwitch = processes.count
        spinRunLoop(for: 0.2)
        // One tick may already have been handed to the queue when the timer was cancelled.
        expect(processes.count <= afterSwitch + 1, "switching to a tab without .processes stops ps, went \(afterSwitch) -> \(processes.count)")
        expect(samplers.running == [.fastStats], "only the 1-second sampler is left, got \(samplers.running)")

        samplers.update(isVisible: false, feeds: [])
        let afterClose = (fast: fast.count, processes: processes.count)
        waitUntil { fast.count >= afterClose.fast + 2 }
        expect(fast.count >= afterClose.fast + 2, "closing the window leaves the 1-second sampler ticking, went \(afterClose.fast) -> \(fast.count)")
        expect(processes.count == afterClose.processes, "and ps stays stopped, went \(afterClose.processes) -> \(processes.count)")
        expect(samplers.running == [.fastStats], "so only the 1-second sampler runs, got \(samplers.running)")
        samplers.stopAll()
    }

    private static func testSamplersSampleAtOnceWhenStartedAndKeepTheirRhythm() {
        let fast = CallCounter()
        let processes = CallCounter()
        // A minute between ticks: anything seen within the test is the at-once sample on start.
        let samplers = makeTestSamplers(fast: fast, processes: processes, interval: 60)

        samplers.update(isVisible: true, feeds: [])
        waitUntil { fast.count >= 1 }
        expect(fast.count == 1, "a starting sampler reads at once instead of a minute later, got \(fast.count)")

        samplers.update(isVisible: true, feeds: [.processes])
        waitUntil { processes.count >= 1 }
        spinRunLoop(for: 0.1)
        expect(processes.count == 1, "the process sampler reads at once when a tab starts wanting it, got \(processes.count)")
        expect(fast.count == 1, "a sampler that keeps running is not restarted by a tab switch, so it keeps its rhythm, got \(fast.count)")
        samplers.update(isVisible: false, feeds: [])
        spinRunLoop(for: 0.1)
        expect(fast.count == 1, "nor by the window closing, got \(fast.count)")
        samplers.stopAll()
    }

    private static func testSamplersFillTheFeeds() {
        let processFeed = Feed(initial: ProcessSummary())
        let fastFeed = Feed(initial: FastStatsSnapshot())
        var reading = FastStatsSnapshot()
        reading.cpuUsagePercent = 42
        let row = ProcessSnapshot(name: "clang", count: 1, physical: 1, virtualSize: 1, cpu: 1)
        let samplers = makeTestSamplers(
            fast: CallCounter(),
            processes: CallCounter(),
            processFeed: processFeed,
            fastFeed: fastFeed,
            fastReading: reading,
            processReading: ProcessSummary(rows: [row], memoryLimit: 1, cpuLimit: 1)
        )
        samplers.update(isVisible: true, feeds: [.processes])
        waitUntil { fastFeed.value.cpuUsagePercent == 42 && processFeed.value.totalCount == 1 }
        expect(fastFeed.value.cpuUsagePercent == 42, "the 1-second reading lands in the fastStats feed plugins read")
        expect(processFeed.value.topCPU.map(\.name) == ["clang"], "the process reading lands in the processes feed plugins read")
        samplers.stopAll()
    }

    private static func testSamplersRunNoPsWhenClosedBeforeItsFirstReadingRuns() {
        let fast = CallCounter()
        let processes = CallCounter()
        let queues = makeHeldQueues()
        // A minute between ticks: anything seen within the test is a first reading.
        let samplers = makeTestSamplers(fast: fast, processes: processes, interval: 60, fastQueue: queues.fast, processQueue: queues.processes)

        samplers.update(isVisible: true, feeds: [.processes])
        samplers.update(isVisible: false, feeds: [])
        queues.fast.resume()
        queues.processes.resume()
        spinRunLoop(for: 0.2)

        expect(processes.count == 0, "a window closed before ps's first reading runs takes that reading back, got \(processes.count)")
        expect(fast.count == 1, "while the 1-second sampler keeps its one first reading, got \(fast.count)")
        expect(samplers.running == [.fastStats], "and keeps running, got \(samplers.running)")
        samplers.stopAll()
    }

    private static func testSamplersStillSampleAfterAQuickCloseAndReopen() {
        let fast = CallCounter()
        let processes = CallCounter()
        let queues = makeHeldQueues()
        // A minute between ticks: anything seen within the test is an at-once reading on start.
        let samplers = makeTestSamplers(fast: fast, processes: processes, interval: 60, fastQueue: queues.fast, processQueue: queues.processes)

        samplers.update(isVisible: true, feeds: [.processes])
        samplers.update(isVisible: false, feeds: [])
        samplers.update(isVisible: true, feeds: [.processes])
        queues.fast.resume()
        queues.processes.resume()
        waitUntil { fast.count >= 1 && processes.count >= 1 }
        spinRunLoop(for: 0.1)

        expect(fast.count == 1 && processes.count == 1, "closing takes back only that start's first reading, so the reopen still reads once, got fast \(fast.count) processes \(processes.count)")
        expect(samplers.running == [.fastStats, .processes], "and both samplers are running again, got \(samplers.running)")
        samplers.stopAll()
    }

    // MARK: - Presenter

    /// A presenter over a fast scheduler and fast samplers, whose collectors count their calls.
    private static func makeTestPresenter(fast: CallCounter, processes: CallCounter) -> (TabPresenter, HostSamplers) {
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        return (TabPresenter(scheduler: makeTestScheduler(), samplers: samplers), samplers)
    }

    private static func testPresenterRunsOnlyTheFastSamplerWhileTheWindowIsClosed() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes, .fastStats])
        presenter.present(plugin: tab, isVisible: false)
        waitUntil { fast.count >= 2 }
        expect(tab.count == 0 && processes.count == 0,
               "a closed window collects no tab and runs no ps, got collect \(tab.count) processes \(processes.count)")
        expect(fast.count >= 2, "but the 1-second sampler keeps the histories going, got \(fast.count)")
        expect(samplers.running == [.fastStats], "so it is the one sampler running, got \(samplers.running)")
        expect(tab.visibility == [false], "the tab is told it is hidden, got \(tab.visibility)")
        samplers.stopAll()
    }

    private static func testPresenterSwitchRunsOnlyTheShownTabsSamplers() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let first = DeclaringTab(feeds: [.processes])
        let second = DeclaringTab(feeds: [])

        presenter.present(plugin: first, isVisible: true)
        waitUntil { first.count >= 1 && processes.count >= 1 }
        expect(samplers.running == [.fastStats, .processes], "a tab that declares the process feed gets both samplers, got \(samplers.running)")

        presenter.switching(from: first, to: second)
        expect(samplers.running == [.fastStats], "switching to a tab that declares nothing stops ps and keeps the 1-second sampler, got \(samplers.running)")
        expect(first.visibility == [true, false] && second.visibility == [true], "each tab is told when it is shown and hidden, got \(first.visibility) and \(second.visibility)")
        waitUntil { second.count >= 1 }
        spinRunLoop(for: 0.1)
        let firstAfter = first.count
        let processesAfter = processes.count
        spinRunLoop(for: 0.2)
        expect(first.count == firstAfter, "the tab switched away from is no longer collected, got \(first.count - firstAfter) more")
        expect(processes.count == processesAfter, "and ps no longer runs, got \(processes.count - processesAfter) more")
        expect(second.count >= 2, "the shown tab is collected on its interval, got \(second.count)")
        presenter.present(plugin: second, isVisible: false)
        samplers.stopAll()
    }

    private static func testPresenterPausesEverythingForAnErrorTab() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes])
        presenter.present(plugin: tab, isVisible: true)
        waitUntil { tab.count >= 1 }

        presenter.switching(from: tab, to: nil)
        expect(samplers.running == [.fastStats], "an error tab declares nothing, so ps stops and only the 1-second sampler runs, got \(samplers.running)")
        spinRunLoop(for: 0.1)
        let collected = tab.count
        spinRunLoop(for: 0.2)
        expect(tab.count == collected, "and the tab switched away from stops, got \(tab.count - collected) more")
        expect(tab.visibility == [true, false], "it is told it is hidden, got \(tab.visibility)")
        samplers.stopAll()
    }

    private static func testPresenterStopsTheTabAndPsWhenTheWindowCloses() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes])
        presenter.present(plugin: tab, isVisible: true)
        waitUntil { tab.count >= 1 && fast.count >= 1 && processes.count >= 1 }

        presenter.present(plugin: tab, isVisible: false)
        expect(samplers.running == [.fastStats], "closing the window stops ps and keeps the 1-second sampler, got \(samplers.running)")
        spinRunLoop(for: 0.1)
        let counts = (tab: tab.count, fast: fast.count, processes: processes.count)
        waitUntil { fast.count >= counts.fast + 2 }
        expect(tab.count == counts.tab && processes.count == counts.processes,
               "neither the tab nor ps runs after it closes, got collect \(tab.count - counts.tab) and ps \(processes.count - counts.processes) more")
        expect(fast.count >= counts.fast + 2, "while the 1-second sampler carries on, went \(counts.fast) -> \(fast.count)")
        samplers.stopAll()
    }

    // MARK: - Fast stats

    private static func testFastStatsSamplerTurnsCountersIntoRates() {
        let sampler = FastStatsSampler()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = sampler.sample(
            cpu: CPUCounters(user: 100, system: 50, idle: 850, nice: 0),
            network: NetworkCounters(received: 1_000, sent: 500),
            at: start
        )
        expect(first.cpuUsagePercent == 0 && first.currentDownloadRate == 0, "a first sample has nothing to compare with, so it reports zero rather than a lifetime average")

        let second = sampler.sample(
            cpu: CPUCounters(user: 130, system: 60, idle: 910, nice: 0),
            network: NetworkCounters(received: 3_000, sent: 1_500),
            at: start.addingTimeInterval(2)
        )
        expect(second.cpuUsagePercent == 40, "40 busy ticks out of 100 is 40%, got \(second.cpuUsagePercent)")
        expect(second.currentDownloadRate == 1_000, "2000 bytes received over 2 seconds is 1000 B/s, got \(second.currentDownloadRate)")
        expect(second.currentUploadRate == 500, "1000 bytes sent over 2 seconds is 500 B/s, got \(second.currentUploadRate)")
        expect(second.cpuHistory == [0, 40], "each sample appends to the history, got \(second.cpuHistory)")

        let reset = sampler.sample(
            cpu: CPUCounters(user: 0, system: 0, idle: 0, nice: 0),
            network: NetworkCounters(received: 0, sent: 0),
            at: start.addingTimeInterval(3)
        )
        expect(reset.currentDownloadRate == 0, "a counter that went backwards (an interface reset) reads as no traffic, not a huge wrapped number")
        expect(reset.cpuUsagePercent == 40, "with no CPU time elapsed the last percent stands, got \(reset.cpuUsagePercent)")
    }

    /// The Mac slept for an hour: the timer did not fire, so the next sample comes an hour after
    /// the one before. Rates divide by the time that really passed, so the first one after waking
    /// is the hour's average, not the hour's bytes as if they moved in one second.
    private static func testFastStatsSamplerDoesNotSpikeAfterALongGap() {
        let sampler = FastStatsSampler()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = sampler.sample(
            cpu: CPUCounters(user: 100, system: 50, idle: 850, nice: 0),
            network: NetworkCounters(received: 1_000, sent: 500),
            at: start
        )
        let afterWake = sampler.sample(
            cpu: CPUCounters(user: 36_100, system: 18_050, idle: 306_850, nice: 0),
            network: NetworkCounters(received: 3_601_000, sent: 360_500),
            at: start.addingTimeInterval(3_600)
        )
        expect(afterWake.currentDownloadRate == 1_000, "3.6 MB over an hour asleep reads 1000 B/s, not 3.6 MB/s, got \(afterWake.currentDownloadRate)")
        expect(afterWake.currentUploadRate == 100, "360 KB sent over the hour reads 100 B/s, got \(afterWake.currentUploadRate)")
        expect(afterWake.cpuUsagePercent == 15, "CPU is a share of the ticks that passed, so it stays a percent, got \(afterWake.cpuUsagePercent)")
        expect(afterWake.downloadHistory.count == 2, "the gap adds one point to the history, not an hour of them, got \(afterWake.downloadHistory.count)")
    }

    /// The totals are the raw since-boot counters summed over the physical interfaces in this
    /// reading: there from the first reading, past 4 GiB, without the VPN, and lower when an
    /// interface goes away.
    private static func testFastStatsSamplerCarriesTotalsSinceBoot() {
        let sampler = FastStatsSampler()
        let start = Date(timeIntervalSince1970: 1_000)
        let cpu = CPUCounters(user: 100, system: 50, idle: 850, nice: 0)
        let fiveGiB: UInt64 = 5 << 30
        let first = sampler.sample(
            cpu: cpu,
            network: traffic(["en0": (fiveGiB, 2_000), "en7": (3_000, 400), "utun4": (9_000, 9_000)]),
            at: start
        )
        expect(first.bytesReceivedSinceBoot == fiveGiB + 3_000, "the first reading already carries the totals, summed over en0 and en7 past 4 GiB, got \(first.bytesReceivedSinceBoot)")
        expect(first.bytesSentSinceBoot == 2_400, "and sent the same way, without the VPN's bytes, got \(first.bytesSentSinceBoot)")

        let unplugged = sampler.sample(cpu: cpu, network: traffic(["en0": (fiveGiB + 1_000, 2_100)]), at: start.addingTimeInterval(1))
        expect(unplugged.bytesReceivedSinceBoot == fiveGiB + 1_000, "an unplugged adapter takes its bytes out of the total, got \(unplugged.bytesReceivedSinceBoot)")
        expect(unplugged.bytesSentSinceBoot == 2_100, "so the sent total goes down too, got \(unplugged.bytesSentSinceBoot)")
        expect(unplugged.currentDownloadRate == 1_000, "while the rate counts only en0's real traffic, got \(unplugged.currentDownloadRate)")

        expect(FastStatsSnapshot().bytesReceivedSinceBoot == 0 && FastStatsSnapshot().bytesSentSinceBoot == 0, "an empty reading's totals are zero")
    }

    private static func traffic(_ interfaces: [String: (received: UInt64, sent: UInt64)]) -> NetworkCounters {
        NetworkCounters(interfaces: interfaces.map { InterfaceCounters(name: $0.key, received: $0.value.received, sent: $0.value.sent) })
    }

    private static func downloadRate(from before: NetworkCounters, to after: NetworkCounters) -> Double? {
        let start = Date(timeIntervalSince1970: 1_000)
        return FastStatsSampler.rates(from: before, at: start, to: after, at: start.addingTimeInterval(1))?.download
    }

    private static func testNetworkCountersKeepOnlyPhysicalInterfaces() {
        let thisMac = ["lo0", "gif0", "stf0", "anpi0", "anpi1", "anpi2", "en0", "en1", "en5", "bridge0",
                       "utun0", "utun6", "ap1", "awdl0", "llw0"]
        let counters = traffic(Dictionary(uniqueKeysWithValues: thisMac.map { ($0, (received: 1, sent: 1)) }))
        expect(Set(counters.interfaces.keys) == ["en0", "en1", "en5"], "only en* interfaces are physical, got \(counters.interfaces.keys.sorted())")
    }

    private static func testNetworkRateIsRightAcrossThe32BitBoundary() {
        // en0 on the Mac this was written on had received 124.9 GB since boot, 29 times past 2^32.
        let before = traffic(["en0": (received: 4_294_966_296, sent: 124_912_442_956)])
        let after = traffic(["en0": (received: 4_294_968_296, sent: 124_912_443_956)])
        let start = Date(timeIntervalSince1970: 1_000)
        let rates = FastStatsSampler.rates(from: before, at: start, to: after, at: start.addingTimeInterval(1))
        expect(rates?.download == 2_000, "a counter crossing 2^32 still gives the bytes that moved, got \(String(describing: rates))")
        expect(rates?.upload == 1_000, "and so does one far past it")
    }

    private static func testVPNTrafficCountsOnce() {
        // A download through a VPN arrives on en0 and again, decrypted, on utun3.
        let before = traffic(["en0": (received: 10_000, sent: 0), "utun3": (received: 5_000, sent: 0)])
        let after = traffic(["en0": (received: 11_000, sent: 0), "utun3": (received: 6_000, sent: 0)])
        expect(downloadRate(from: before, to: after) == 1_000, "the tunnel's copy of the traffic is not added, got \(String(describing: downloadRate(from: before, to: after)))")
    }

    private static func testAnInterfaceComingOrGoingIsNoSpike() {
        let plugged = downloadRate(
            from: traffic(["en0": (received: 1_000, sent: 0)]),
            to: traffic(["en0": (received: 2_000, sent: 0), "en5": (received: 50_000_000_000, sent: 0)])
        )
        expect(plugged == 1_000, "an interface that appears adds nothing until it has a reading to compare with, got \(String(describing: plugged))")
        let unplugged = downloadRate(
            from: traffic(["en0": (received: 1_000, sent: 0), "en5": (received: 50_000_000_000, sent: 0)]),
            to: traffic(["en0": (received: 2_000, sent: 0)])
        )
        expect(unplugged == 1_000, "an interface that disappears takes nothing away, got \(String(describing: unplugged))")
        let reset = downloadRate(
            from: traffic(["en0": (received: 50_000, sent: 0), "en5": (received: 900, sent: 0)]),
            to: traffic(["en0": (received: 10, sent: 0), "en5": (received: 1_900, sent: 0)])
        )
        expect(reset == 1_000, "a counter that went backwards counts as nothing, and the others still count, got \(String(describing: reset))")
    }

    /// The counters the sampler reads are netstat's own, all 64 bits: an app reading the route
    /// table or getifaddrs instead gets them cut to 32 bits and rounded to a KiB, which a check
    /// of the low bits alone would not catch. Traffic between the two reads may move them a little.
    /// It is decisive only once en0 has moved more than 4 GiB since boot; before that the cut
    /// counters and the whole ones agree but for the KiB rounding.
    private static func testInterfaceCountersAgreeWithNetstat() {
        let ours = FastStatsSampler.readInterfaceCounters()
        let netstat = ProcessRunner.run(path: "/usr/sbin/netstat", arguments: ["-ib"], environment: nil, timeout: ProcessRunner.defaultTimeout)
        expect(ours.contains { NetworkCounters.isPhysical($0.name) }, "this Mac's physical interfaces are among those read, got \(ours.map(\.name))")
        expect(netstat.status == 0, "netstat -ib runs, got status \(netstat.status)")
        let theirs = netstatReceivedBytes(netstat.output)
        for interface in ours {
            guard let reference = theirs[interface.name] else { continue }
            let drift = Int64(bitPattern: reference &- interface.received)
            expect((0..<64 * 1_048_576).contains(drift), "\(interface.name): read \(interface.received) bytes received, netstat says \(reference)")
        }
        expect(ours.contains { theirs[$0.name] != nil }, "at least one interface is checked against netstat")
    }

    /// Ibytes per interface from `netstat -ib`'s link rows. A row may lack its address column, so
    /// Ibytes is found from the end: Ibytes, Opkts, Oerrs, Obytes, Coll.
    private static func netstatReceivedBytes(_ output: String) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 8, fields[2].hasPrefix("<Link#"), let bytes = UInt64(fields[fields.count - 5]) else { continue }
            result[String(fields[0])] = bytes
        }
        return result
    }

    private static func testFastStatsSamplerKeepsNinetySeconds() {
        let sampler = FastStatsSampler()
        let start = Date(timeIntervalSince1970: 1_000)
        let last = (0..<100).reduce(FastStatsSnapshot()) { _, second in
            sampler.sample(
                cpu: CPUCounters(user: UInt64(second) * 10, system: 0, idle: UInt64(second) * 90, nice: 0),
                network: NetworkCounters(received: UInt64(second) * 100, sent: 0),
                at: start.addingTimeInterval(TimeInterval(second))
            )
        }
        expect(last.cpuHistory.count == FastStatsSampler.historyLimit, "the CPU history keeps the last \(FastStatsSampler.historyLimit) samples, got \(last.cpuHistory.count)")
        expect(last.downloadHistory.count == FastStatsSampler.historyLimit && last.uploadHistory.count == FastStatsSampler.historyLimit, "and so do both network histories")
        expect(FastStatsSampler.historyLimit == 90, "90 one-second samples is the 'last 90s' the graphs are labelled with")
    }

    private static func testFastStatsSamplerReportsPerCoreAndUserSystemShares() {
        let sampler = FastStatsSampler()
        let start = Date(timeIntervalSince1970: 1_000)
        let quiet = NetworkCounters(received: 0, sent: 0)

        let first = sampler.sample(
            cpu: CPUCounters(cores: [
                CoreTicks(user: 0, system: 0, idle: 0, nice: 0),
                CoreTicks(user: 0, system: 0, idle: 0, nice: 0),
            ]),
            network: quiet,
            at: start
        )
        expect(first.perCoreUsage.isEmpty && first.cpuUserPercent == 0 && first.cpuSystemPercent == 0, "a first sample has no per-core or user/system figures yet")

        let second = sampler.sample(
            cpu: CPUCounters(cores: [
                CoreTicks(user: 60, system: 20, idle: 20, nice: 0),   // 80% busy
                CoreTicks(user: 10, system: 0, idle: 80, nice: 10),   // 20% busy; nice counts as user
            ]),
            network: quiet,
            at: start.addingTimeInterval(1)
        )
        expect(second.perCoreUsage == [80, 20], "each core's busy percent over the interval, in the kernel's order, got \(second.perCoreUsage)")
        expect(second.cpuUsagePercent == 50, "the headline is still the whole machine's busy percent, got \(second.cpuUsagePercent)")
        expect(second.cpuUserPercent == 40 && second.cpuSystemPercent == 10, "user (with nice) and system as shares of all cores: 80 of 200 ticks and 20 of 200, got \(second.cpuUserPercent)/\(second.cpuSystemPercent)")

        let fewerCores = sampler.sample(
            cpu: CPUCounters(cores: [CoreTicks(user: 100, system: 0, idle: 0, nice: 0)]),
            network: quiet,
            at: start.addingTimeInterval(2)
        )
        expect(fewerCores.perCoreUsage == [80, 20], "a reading with a different core count keeps the last per-core figures rather than pairing the wrong cores, got \(fewerCores.perCoreUsage)")
    }

    // MARK: - Process sampler

    /// `ps -eo pid,rss,vsz,pcpu,comm -r` output: rss and vsz in kilobytes.
    private static let psRows = """
      PID    RSS      VSZ  %CPU COMM
      101   2048   400000  10.0 /usr/bin/clang
      102   4096   400000  30.0 /usr/bin/clang
      103    512   100000  90.0 /usr/libexec/tiny
      104   3072   200000   5.0 /Applications/Safari.app/Contents/MacOS/Safari
    """

    private static func testProcessSamplerGroupsRowsAndDropsTinyOnes() {
        let samples = ProcessSampler.parsePS(psRows)
        expect(samples.count == 4, "every row but the header is read, got \(samples.count)")

        let rows = ProcessSampler.snapshots(samples: samples, footprint: { _ in nil })
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        expect(byName["tiny"] == nil, "a process under a megabyte resident is noise in a top-N list and is dropped")
        expect(byName["clang"]?.count == 2, "processes with one name are one group")
        expect(byName["clang"]?.physical == 6_144 * 1_024, "a group's memory is the sum of its members', in bytes")
        expect(byName["clang"]?.cpu == 40, "and so is its CPU")
        expect(byName["Safari"]?.physical == 3_072 * 1_024, "the name is the executable's basename")
    }

    private static func testProcessSamplerUsesTheFootprintOnlyForShownGroups() {
        let samples = ProcessSampler.parsePS(psRows)
        let asked = LogRecorder()
        let rows = ProcessSampler.snapshots(samples: samples, memoryLimit: 1, cpuLimit: 1) { pid in
            asked.record("\(pid)")
            return 1
        }
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        expect(Set(asked.messages) == ["101", "102"], "only the group that would be shown (clang, top by memory and by CPU) pays for the footprint syscall, got \(asked.messages)")
        expect(byName["clang"]?.physical == 2, "a refined group's memory is the sum of its footprints")
        expect(byName["Safari"]?.physical == 3_072 * 1_024, "an unrefined group keeps ps's resident size")
    }

    private static func testProcessSamplerRunsPsThroughTheRunner() {
        let recorder = LogRecorder()
        let runner = recordingRunner(recorder, answers: ["/bin/ps -eo pid,rss,vsz,pcpu,comm -r": psRows])
        let summary = ProcessSampler.summary(runner: runner, footprint: { _ in nil })
        expect(recorder.messages == ["/bin/ps -eo pid,rss,vsz,pcpu,comm -r"], "one ps, by explicit path, with an argument array, got \(recorder.messages)")
        expect(summary.totalCount == 2, "the summary counts groups after the tiny one is dropped, got \(summary.totalCount)")
        expect(summary.topCPU.first?.name == "clang", "and ranks them by CPU")
    }
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

/// Counts calls from any thread, for the samplers' fake collectors.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func increment() {
        lock.withLock { calls += 1 }
    }

    var count: Int { lock.withLock { calls } }
}

/// A tab that declares whatever feeds a test gives it, counts its collects, and records each
/// visibility change it is told about, in order.
final class DeclaringTab: TabPlugin {
    static let identifier = "declaring"
    let title = "Declaring"
    let systemImage = "list.bullet"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 0.05
    let sharedFeeds: Set<SharedFeed>
    private let lock = NSLock()
    private var collects = 0
    /// Main thread only: the presenter calls visibilityChanged there.
    private(set) var visibility: [Bool] = []

    init(host: HostServices) {
        sharedFeeds = []
    }

    init(feeds: Set<SharedFeed>) {
        sharedFeeds = feeds
    }

    func collect() {
        lock.withLock { collects += 1 }
    }

    func visibilityChanged(isVisible: Bool) {
        visibility = visibility + [isVisible]
    }

    var count: Int { lock.withLock { collects } }
    @MainActor func makeView() -> AnyView { AnyView(Text("declaring")) }
}

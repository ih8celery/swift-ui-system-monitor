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
        testSamplersWantNothingWhileTheWindowIsClosed()
        testSamplersRunNothingWhileTheWindowIsClosed()
        testSamplersRunTheFastSamplerForEveryVisibleTab()
        testSamplersRunTheProcessSamplerOnlyWhileATabDeclaresIt()
        testSamplersSampleAtOnceWhenStartedAndKeepTheirRhythm()
        testSamplersFillTheFeeds()
        testSamplersRunNothingWhenClosedBeforeTheFirstReadingRuns()
        testSamplersStillSampleAfterAQuickCloseAndReopen()
        testFastStatsSamplerTurnsCountersIntoRates()
        testFastStatsSamplerKeepsNinetySeconds()
        testProcessSamplerGroupsRowsAndDropsTinyOnes()
        testProcessSamplerUsesTheFootprintOnlyForShownGroups()
        testProcessSamplerRunsPsThroughTheRunner()
        testPresenterRunsNothingWhileTheWindowIsClosed()
        testPresenterSwitchRunsOnlyTheShownTabsSamplers()
        testPresenterPausesEverythingForAnErrorTab()
        testPresenterStopsEverythingWhenTheWindowCloses()
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
        let scheduler = PluginScheduler(log: { log.record($0) })
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
        waitUntil(2) { plugin.count > atWake }
        expect(plugin.count > atWake, "after the settle, the background cadence resumes")

        // The screens waking is the other signal the real app hears.
        let beforeScreens = plugin.count
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        spinRunLoop(for: 0.15)
        expect(plugin.count <= beforeScreens + 1, "screensDidWake also restarts the timer with a settle, got \(plugin.count - beforeScreens) ticks in half the settle")
    }

    private static func testSchedulerLeavesTheShownTabAloneAfterAWake() {
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
        scheduler.show(plugin)
        waitUntil { plugin.count >= 2 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let atWake = plugin.count
        waitUntil { plugin.count >= atWake + 3 }
        expect(plugin.count >= atWake + 3, "a wake does not touch the shown tab's fast timer, got \(plugin.count - atWake) ticks")
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

    private static func testSamplersWantNothingWhileTheWindowIsClosed() {
        expect(HostSamplers.wanted(isVisible: false, feeds: [.processes, .fastStats]).isEmpty, "a closed window wants no sampler, whatever the tab declares")
        expect(HostSamplers.wanted(isVisible: true, feeds: []) == [.fastStats], "an open window always wants the 1-second sampler, so the histories have no gaps")
        expect(HostSamplers.wanted(isVisible: true, feeds: [.processes]) == [.fastStats, .processes], "a tab that declares the process feed adds the process sampler")
    }

    private static func testSamplersRunNothingWhileTheWindowIsClosed() {
        let fast = CallCounter()
        let processes = CallCounter()
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        samplers.update(isVisible: false, feeds: [.processes, .fastStats])
        spinRunLoop(for: 0.2)
        expect(fast.count == 0 && processes.count == 0, "a closed window runs no sampler, got fast \(fast.count) processes \(processes.count)")
        expect(samplers.running.isEmpty, "and reports none running, got \(samplers.running)")
    }

    private static func testSamplersRunTheFastSamplerForEveryVisibleTab() {
        let fast = CallCounter()
        let processes = CallCounter()
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        samplers.update(isVisible: true, feeds: [])
        waitUntil { fast.count >= 3 }
        expect(fast.count >= 3, "the 1-second sampler ticks for a tab that declares nothing, got \(fast.count)")
        expect(processes.count == 0, "but ps never runs for it, got \(processes.count)")
        samplers.update(isVisible: false, feeds: [])
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
        let afterClose = fast.count
        spinRunLoop(for: 0.2)
        expect(fast.count <= afterClose + 1, "closing the window stops the 1-second sampler too, went \(afterClose) -> \(fast.count)")
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
        samplers.update(isVisible: false, feeds: [])
    }

    private static func testSamplersRunNothingWhenClosedBeforeTheFirstReadingRuns() {
        let fast = CallCounter()
        let processes = CallCounter()
        let queues = makeHeldQueues()
        let samplers = makeTestSamplers(fast: fast, processes: processes, fastQueue: queues.fast, processQueue: queues.processes)

        samplers.update(isVisible: true, feeds: [.processes])
        samplers.update(isVisible: false, feeds: [])
        queues.fast.resume()
        queues.processes.resume()
        spinRunLoop(for: 0.2)

        expect(fast.count == 0 && processes.count == 0, "a window closed before the first reading runs takes that reading back, got fast \(fast.count) processes \(processes.count)")
        expect(samplers.running.isEmpty, "and reports none running, got \(samplers.running)")
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
        samplers.update(isVisible: false, feeds: [])
    }

    // MARK: - Presenter

    /// A presenter over a fast scheduler and fast samplers, whose collectors count their calls.
    private static func makeTestPresenter(fast: CallCounter, processes: CallCounter) -> (TabPresenter, HostSamplers) {
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        return (TabPresenter(scheduler: makeTestScheduler(), samplers: samplers), samplers)
    }

    private static func testPresenterRunsNothingWhileTheWindowIsClosed() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes, .fastStats])
        presenter.present(plugin: tab, isVisible: false)
        spinRunLoop(for: 0.2)
        expect(tab.count == 0 && fast.count == 0 && processes.count == 0,
               "a closed window collects nothing and samples nothing, got collect \(tab.count) fast \(fast.count) processes \(processes.count)")
        expect(samplers.running.isEmpty, "and no sampler is left running, got \(samplers.running)")
        expect(tab.visibility == [false], "the tab is told it is hidden, got \(tab.visibility)")
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
    }

    private static func testPresenterPausesEverythingForAnErrorTab() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes])
        presenter.present(plugin: tab, isVisible: true)
        waitUntil { tab.count >= 1 }

        presenter.switching(from: tab, to: nil)
        expect(samplers.running.isEmpty, "an error tab has nothing to feed, so no sampler runs, got \(samplers.running)")
        spinRunLoop(for: 0.1)
        let collected = tab.count
        spinRunLoop(for: 0.2)
        expect(tab.count == collected, "and the tab switched away from stops, got \(tab.count - collected) more")
        expect(tab.visibility == [true, false], "it is told it is hidden, got \(tab.visibility)")
    }

    private static func testPresenterStopsEverythingWhenTheWindowCloses() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes])
        presenter.present(plugin: tab, isVisible: true)
        waitUntil { tab.count >= 1 && fast.count >= 1 && processes.count >= 1 }

        presenter.present(plugin: tab, isVisible: false)
        expect(samplers.running.isEmpty, "closing the window stops both samplers, got \(samplers.running)")
        spinRunLoop(for: 0.1)
        let counts = (tab.count, fast.count, processes.count)
        spinRunLoop(for: 0.2)
        expect((tab.count, fast.count, processes.count) == counts, "and nothing runs after it closes, got \((tab.count, fast.count, processes.count)) after \(counts)")
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

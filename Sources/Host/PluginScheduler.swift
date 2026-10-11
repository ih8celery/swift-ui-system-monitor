import AppKit
import Foundation
import SystemBarKit

/// Runs each plugin's `collect()` on a queue the host owns for it: every `refreshInterval`
/// seconds while its tab is showing and, for a plugin that declares a `backgroundInterval`,
/// every that many seconds while it is not. One serial queue per plugin, so the two cadences
/// never overlap and a slow collect delays the next tick rather than running beside it. Only one
/// plugin is shown at a time, enforced here: showing a different plugin returns the previous one
/// to its background cadence, or to nothing. After the Mac wakes, every background timer is
/// restarted with its first tick `settleAfterWake` later, because a Dispatch timer that missed
/// its deadline during sleep fires the instant the Mac wakes, which would land a sample on the
/// login moment. Main thread only.
@MainActor
final class PluginScheduler {
    private struct Slot {
        let plugin: TabPlugin
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
    }

    /// The floor under any plugin's declared refreshInterval, so a bad bundle cannot spin a core or trap.
    nonisolated static let minimumRefreshInterval: TimeInterval = 0.25
    /// The ceiling for both intervals: a day is the longest a tab can sensibly wait, and Dispatch traps far above it.
    nonisolated static let maximumRefreshInterval: TimeInterval = 86_400
    /// The floor under a declared backgroundInterval. A hidden tab is the app's idle cost, so it
    /// may not sample faster than this however small the bundle's number.
    nonisolated static let minimumBackgroundInterval: TimeInterval = 5
    /// How long after a wake the first background tick waits.
    nonisolated static let backgroundSettleAfterWake: TimeInterval = 120

    private var slots: [ObjectIdentifier: Slot] = [:]
    private var shown: TabPlugin?
    private let minimumRefreshInterval: TimeInterval
    private let minimumBackgroundInterval: TimeInterval
    private let maximumRefreshInterval: TimeInterval
    private let settleAfterWake: TimeInterval
    private let wakeNotifications: NotificationCenter
    private var wakeObservers: [NSObjectProtocol] = []
    private let log: (String) -> Void

    /// The bounds, the settle, the notification center and `log` default to the real app's, but
    /// a test can override any of them — short floors so its fakes run at their own declared
    /// intervals, a center of its own so it can post a wake, and a capturing closure instead of
    /// NSLog — without any of it leaking into the real app.
    init(
        minimumRefreshInterval: TimeInterval = PluginScheduler.minimumRefreshInterval,
        minimumBackgroundInterval: TimeInterval = PluginScheduler.minimumBackgroundInterval,
        maximumRefreshInterval: TimeInterval = PluginScheduler.maximumRefreshInterval,
        settleAfterWake: TimeInterval = PluginScheduler.backgroundSettleAfterWake,
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        log: @escaping (String) -> Void = { NSLog("%@", $0) }
    ) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.minimumBackgroundInterval = minimumBackgroundInterval
        self.maximumRefreshInterval = maximumRefreshInterval
        self.settleAfterWake = settleAfterWake
        self.wakeNotifications = wakeNotifications
        self.log = log
        observeWakes()
    }

    deinit {
        wakeObservers.forEach { wakeNotifications.removeObserver($0) }
        slots.values.forEach { $0.timer?.cancel() }
    }

    // MARK: - Intervals

    /// A declared refreshInterval clamped between this scheduler's minimum and maximum. Zero
    /// would spin its queue's thread and a negative or NaN value would trap the timer, so those
    /// take the minimum. Dispatch counts the interval in nanoseconds in a UInt64 and traps on a
    /// huge one, so anything above the maximum takes the maximum — including infinity, which
    /// reads as "hardly ever", not "as fast as possible". The substitution is logged each time.
    func effectiveInterval(_ declared: TimeInterval, identifier: String) -> TimeInterval {
        let clamped = Self.clamp(declared, floor: minimumRefreshInterval, ceiling: maximumRefreshInterval)
        if clamped != declared {
            log("SystemBar: \(identifier) asked for a refreshInterval of \(declared); using \(clamped)")
        }
        return clamped
    }

    /// A declared backgroundInterval clamped the same way, against the background floor.
    func effectiveBackgroundInterval(_ declared: TimeInterval, identifier: String) -> TimeInterval {
        let clamped = Self.clamp(declared, floor: minimumBackgroundInterval, ceiling: maximumRefreshInterval)
        if clamped != declared {
            log("SystemBar: \(identifier) asked for a backgroundInterval of \(declared); using \(clamped)")
        }
        return clamped
    }

    /// What a declared backgroundInterval becomes in the real app, for `--list-plugins` to
    /// report the cadence that would actually run.
    nonisolated static func reportedBackgroundInterval(_ declared: TimeInterval) -> TimeInterval {
        clamp(declared, floor: minimumBackgroundInterval, ceiling: maximumRefreshInterval)
    }

    nonisolated private static func clamp(_ declared: TimeInterval, floor: TimeInterval, ceiling: TimeInterval) -> TimeInterval {
        if declared.isNaN { return floor }
        return min(max(declared, floor), ceiling)
    }

    // MARK: - Showing and hiding

    /// At launch: every plugin that declares a background interval starts its slow timer, first
    /// tick one interval from now. A plugin that declares nothing is left alone until shown.
    /// A plugin already shown keeps its fast timer, so calling this in any order is safe.
    func start(_ plugins: [TabPlugin]) {
        for plugin in plugins where plugin.backgroundInterval != nil && plugin !== shown {
            startBackgroundTimer(for: plugin, firstTickAfter: nil)
        }
    }

    /// Shows `plugin`: returns whichever plugin was previously shown to its background cadence,
    /// if it is a different one, then starts this plugin's fast timer on its own serial queue —
    /// immediately, then every clamped `refreshInterval`. The queue is kept in `slots` across
    /// hides and shows, so a collect still running from the slow timer finishes before the
    /// first fast tick rather than ever overlapping it.
    func show(_ plugin: TabPlugin) {
        if let previous = shown, previous !== plugin {
            returnToBackground(previous)
        }
        shown = plugin

        let interval = effectiveInterval(plugin.refreshInterval, identifier: type(of: plugin).identifier)
        replaceTimer(for: plugin, firstTickAfter: 0, every: interval)
    }

    /// Hides whichever plugin is currently shown: its fast timer stops, and if it declares a
    /// background interval its slow timer starts, first tick one interval later, since the tab
    /// was collected a moment ago.
    func hide() {
        guard let plugin = shown else { return }
        returnToBackground(plugin)
        shown = nil
    }

    private func returnToBackground(_ plugin: TabPlugin) {
        cancelTimer(for: plugin)
        startBackgroundTimer(for: plugin, firstTickAfter: nil)
    }

    /// Starts (or restarts) the slow timer for a plugin that declares one. `firstTickAfter` nil
    /// means one interval from now.
    private func startBackgroundTimer(for plugin: TabPlugin, firstTickAfter delay: TimeInterval?) {
        guard let declared = plugin.backgroundInterval else { return }
        let interval = effectiveBackgroundInterval(declared, identifier: type(of: plugin).identifier)
        replaceTimer(for: plugin, firstTickAfter: delay ?? interval, every: interval)
    }

    // MARK: - Wake

    private func observeWakes() {
        let names = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification]
        wakeObservers = names.map { name in
            wakeNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.settleBackgroundTimersAfterWake() }
            }
        }
    }

    /// Every hidden plugin with a background interval gets its timer restarted, first tick
    /// `settleAfterWake` from now. The shown tab's fast timer is left alone: the person is
    /// looking at it.
    private func settleBackgroundTimersAfterWake() {
        // Iterate a copy: restarting a timer writes back into `slots`.
        for slot in Array(slots.values) where slot.plugin !== shown {
            startBackgroundTimer(for: slot.plugin, firstTickAfter: settleAfterWake)
        }
    }

    // MARK: - Timers

    private func replaceTimer(for plugin: TabPlugin, firstTickAfter delay: TimeInterval, every interval: TimeInterval) {
        let key = ObjectIdentifier(plugin)
        var slot = slots[key] ?? Slot(
            plugin: plugin,
            queue: DispatchQueue(label: "systembar.plugin.\(type(of: plugin).identifier)", qos: .utility),
            timer: nil
        )
        slot.timer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: slot.queue)
        timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak plugin] in plugin?.collect() }
        timer.resume()
        slot.timer = timer
        slots[key] = slot
    }

    private func cancelTimer(for plugin: TabPlugin) {
        let key = ObjectIdentifier(plugin)
        guard var slot = slots[key] else { return }
        slot.timer?.cancel()
        slot.timer = nil
        slots[key] = slot
    }
}

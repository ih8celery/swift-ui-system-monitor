import Foundation
import SystemBarKit

/// Runs each plugin's `collect()` on a queue the host owns for it, every `refreshInterval`
/// seconds, only while its tab is showing, and never overlapping: the queue is serial, so a slow
/// collect delays the next tick rather than running beside it. Only one plugin is shown at a
/// time, enforced here: showing a different plugin stops whichever one was shown before. Main
/// thread only.
@MainActor
final class PluginScheduler {
    private struct Slot {
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
    }

    /// The floor under any plugin's declared refreshInterval, so a bad bundle cannot spin a core or trap.
    nonisolated static let minimumRefreshInterval: TimeInterval = 0.25
    /// The ceiling: a day is the longest a tab can sensibly wait, and Dispatch traps far above it.
    nonisolated static let maximumRefreshInterval: TimeInterval = 86_400

    private var slots: [ObjectIdentifier: Slot] = [:]
    private var shown: TabPlugin?
    private let minimumRefreshInterval: TimeInterval
    private let maximumRefreshInterval: TimeInterval
    private let log: (String) -> Void

    /// The bounds and `log` default to the real app's floor, ceiling and NSLog, but a test can
    /// override any of them — a short floor so its fakes run at their own declared interval, and
    /// a capturing closure instead of NSLog — without any of it leaking into the real app.
    init(
        minimumRefreshInterval: TimeInterval = PluginScheduler.minimumRefreshInterval,
        maximumRefreshInterval: TimeInterval = PluginScheduler.maximumRefreshInterval,
        log: @escaping (String) -> Void = { NSLog("%@", $0) }
    ) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.maximumRefreshInterval = maximumRefreshInterval
        self.log = log
    }

    /// A declared interval clamped between this scheduler's minimum and maximum. Zero would spin
    /// its queue's thread and a negative or NaN value would trap the timer, so those take the
    /// minimum. Dispatch counts the interval in nanoseconds in a UInt64 and traps on a huge one,
    /// so anything above the maximum takes the maximum — including infinity, which reads as
    /// "hardly ever", not "as fast as possible". The substitution is logged each time.
    func effectiveInterval(_ declared: TimeInterval, identifier: String) -> TimeInterval {
        let clamped = clamp(declared)
        if clamped != declared {
            log("SystemBar: \(identifier) asked for a refreshInterval of \(declared); using \(clamped)")
        }
        return clamped
    }

    private func clamp(_ declared: TimeInterval) -> TimeInterval {
        if declared.isNaN { return minimumRefreshInterval }
        return min(max(declared, minimumRefreshInterval), maximumRefreshInterval)
    }

    /// Shows `plugin`: stops whichever plugin was previously shown, if it is a different one,
    /// then starts (or restarts) this plugin's timer on its own serial queue — immediately, then
    /// every clamped `refreshInterval`. The queue itself is kept in `slots` across hides and
    /// shows, so a plugin resumed after being hidden mid-collect still serializes on the same
    /// queue rather than ever overlapping the next tick.
    func show(_ plugin: TabPlugin) {
        if let previous = shown, previous !== plugin {
            cancelTimer(for: previous)
        }
        shown = plugin

        let key = ObjectIdentifier(plugin)
        var slot = slots[key] ?? Slot(queue: DispatchQueue(label: "systembar.plugin.\(type(of: plugin).identifier)", qos: .utility), timer: nil)
        slot.timer?.cancel()

        let interval = effectiveInterval(plugin.refreshInterval, identifier: type(of: plugin).identifier)

        let timer = DispatchSource.makeTimerSource(queue: slot.queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak plugin] in plugin?.collect() }
        timer.resume()
        slot.timer = timer
        slots[key] = slot
    }

    /// Hides whichever plugin is currently shown: stops its timer and forgets it as the shown
    /// plugin. Its queue stays in `slots`, ready to be reused if it is shown again.
    func hide() {
        guard let plugin = shown else { return }
        cancelTimer(for: plugin)
        shown = nil
    }

    private func cancelTimer(for plugin: TabPlugin) {
        let key = ObjectIdentifier(plugin)
        guard var slot = slots[key] else { return }
        slot.timer?.cancel()
        slot.timer = nil
        slots[key] = slot
    }
}

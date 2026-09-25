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

    private var slots: [ObjectIdentifier: Slot] = [:]
    private var shown: TabPlugin?
    private let minimumRefreshInterval: TimeInterval
    private let log: (String) -> Void

    /// `minimumRefreshInterval` and `log` default to the real app's floor and NSLog, but a test
    /// can override either — a short floor so its fakes run at their own declared interval, and
    /// a capturing closure instead of NSLog — without either leaking into the real app.
    init(
        minimumRefreshInterval: TimeInterval = MonitorSamplingPlan.minimumRefreshInterval,
        log: @escaping (String) -> Void = { NSLog("%@", $0) }
    ) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.log = log
    }

    /// A declared interval clamped to this scheduler's minimum: zero would spin its queue's
    /// thread, and a negative, NaN, or infinite value would trap the timer, so either is floored
    /// instead, and the substitution is logged each time it is applied.
    func effectiveInterval(_ declared: TimeInterval, identifier: String) -> TimeInterval {
        let clamped = declared.isFinite ? max(declared, minimumRefreshInterval) : minimumRefreshInterval
        if clamped != declared {
            log("SystemBar: \(identifier) asked for a refreshInterval of \(declared); using \(clamped)")
        }
        return clamped
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

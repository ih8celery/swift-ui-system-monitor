import Foundation
import SystemBarKit

/// Runs each plugin's `collect()` on a queue the host owns for it, every `refreshInterval`
/// seconds, only while its tab is showing, and never overlapping: the queue is serial, so a slow
/// collect delays the next tick rather than running beside it. Main thread only.
@MainActor
final class PluginScheduler {
    private struct Slot {
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
    }

    private var slots: [ObjectIdentifier: Slot] = [:]

    func setVisible(_ plugin: TabPlugin, _ isVisible: Bool) {
        let key = ObjectIdentifier(plugin)
        var slot = slots[key] ?? Slot(queue: DispatchQueue(label: "systembar.plugin.\(type(of: plugin).identifier)", qos: .utility), timer: nil)
        slot.timer?.cancel()
        slot.timer = nil
        if isVisible {
            let timer = DispatchSource.makeTimerSource(queue: slot.queue)
            timer.schedule(deadline: .now(), repeating: plugin.refreshInterval, leeway: .milliseconds(Int(plugin.refreshInterval * 100)))
            timer.setEventHandler { [weak plugin] in plugin?.collect() }
            timer.resume()
            slot.timer = timer
        }
        slots[key] = slot
    }
}

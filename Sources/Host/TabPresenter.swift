import Foundation
import SystemBarKit

/// The one place that says what is showing. The window opening or closing, and the selection
/// moving, come here; the presenter tells the tab, the scheduler that collects it, and the host's
/// shared samplers. A nil plugin is an error tab or an empty list: it has nothing to collect and
/// nothing to feed, so everything pauses while it is showing.
@MainActor
final class TabPresenter {
    private let scheduler: PluginScheduler
    private let samplers: HostSamplers

    init(scheduler: PluginScheduler, samplers: HostSamplers) {
        self.scheduler = scheduler
        self.samplers = samplers
    }

    /// The window opened (or closed) on `plugin`.
    func present(plugin: TabPlugin?, isVisible: Bool) {
        plugin?.visibilityChanged(isVisible: isVisible)
        if isVisible, let plugin {
            scheduler.show(plugin)
        } else {
            scheduler.hide()
        }
        samplers.update(isVisible: isVisible && plugin != nil, feeds: plugin?.sharedFeeds ?? [])
    }

    /// The selection moved while the window is open. The old tab is told first, so it never
    /// sees the new one shown while it still thinks it is visible.
    func switching(from previous: TabPlugin?, to next: TabPlugin?) {
        previous?.visibilityChanged(isVisible: false)
        present(plugin: next, isVisible: true)
    }
}

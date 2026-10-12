import AppKit
import Foundation
import SwiftUI
import SystemBarKit

/// Runs a plugin's `collect()` once, the way the scheduler would (off the main thread), waits
/// for what it sends back to main, then draws its view.
@MainActor
enum PreviewRenderer {
    /// Longer than `ProcessRunner.defaultTimeout`, so one slow command cannot cut a collect short.
    nonisolated static let collectTimeout: TimeInterval = 60
    /// Time after collect for updates a plugin sends to main from its own queues.
    nonisolated static let settleAfterCollect: TimeInterval = 0.2
    nonisolated static let renderScale: CGFloat = 2
    private nonisolated static let pollInterval: TimeInterval = 0.01

    /// True when collect returned within `timeout`. Anything the plugin queued on main during
    /// collect has run by then: the main queue is first in, first out, and the "finished" mark
    /// is queued after collect returns.
    static func collectOnce(_ plugin: TabPlugin, timeout: TimeInterval = collectTimeout) -> Bool {
        let finished = PreviewFlag()
        let box = PreviewPluginBox(plugin: plugin)
        DispatchQueue(label: "systembar.preview.collect").async {
            box.plugin.collect()
            DispatchQueue.main.async { finished.set() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished.isSet && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }
        guard finished.isSet else { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(settleAfterCollect))
        return true
    }

    static func pngData(of plugin: TabPlugin, size: CGSize, scale: CGFloat = renderScale) -> Data? {
        let content = plugin.makeView()
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Tells the plugin it is showing, collects once, draws and saves. Nil on success, or the
    /// sentence saying what went wrong.
    static func writePicture(of plugin: TabPlugin, size: CGSize, to url: URL) -> String? {
        plugin.visibilityChanged(isVisible: true)
        guard collectOnce(plugin) else {
            return "\(type(of: plugin).identifier)'s collect() did not finish within \(Int(collectTimeout)) s"
        }
        guard let data = pngData(of: plugin, size: size) else {
            return "\(type(of: plugin).identifier)'s view could not be drawn"
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return "could not save the picture to \(url.path): \(error.localizedDescription)"
        }
        return nil
    }
}

/// Set once from main, read from main; locked because it is created on main and captured by a
/// closure that runs on the collect queue.
private final class PreviewFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Carries the plugin to its collect queue, as the scheduler does; the SDK promises collect is
/// safe to call off the main thread.
private struct PreviewPluginBox: @unchecked Sendable {
    let plugin: TabPlugin
}

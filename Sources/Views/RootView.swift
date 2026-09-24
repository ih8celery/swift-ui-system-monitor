import AppKit
import Foundation
import SwiftUI

struct RootView: View {
    // Not observed: the panels observe the monitor themselves; RootView only tells it what is visible.
    let monitor: UnifiedMonitor
    let tabs: [LoadedTab]
    let configPath: String
    /// An index, not an id: a failed tab has no id, and two failures may share a location.
    @State private var selection = 0
    @State private var isRelaunching = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Divider().background(Color.white.opacity(0.08))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 680)
        .background(Palette.background)
        .foregroundStyle(Palette.foreground)
        .onAppear {
            present(index: selection, isVisible: true)
        }
        .onDisappear {
            present(index: selection, isVisible: false)
        }
        .onChange(of: selection) { previous, current in
            loadedPlugin(at: previous)?.visibilityChanged(isVisible: false)
            present(index: current, isVisible: true)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: selectedTab?.systemImage ?? "questionmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28)

            if !tabs.isEmpty {
                Picker("Tab", selection: $selection) {
                    // Keyed by position: the list is fixed at launch. Revisit if tabs can ever change while running.
                    ForEach(Array(tabs.enumerated()), id: \.offset) { offset, tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .help(tab.title)
                            .tag(offset)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .labelsHidden()
            } else {
                Spacer()
            }

            Button {
                relaunch()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isRelaunching)
            .help("Relaunch SystemBar to apply plugins.json")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit SystemBar")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .loaded(_, let plugin)?:
            plugin.makeView()
        case let .failed(location, reason)?:
            ErrorTabView(location: location, reason: reason, configPath: configPath)
        case nil:
            NoTabsView(configPath: configPath)
        }
    }

    private var selectedTab: LoadedTab? {
        tabs.indices.contains(selection) ? tabs[selection] : nil
    }

    private var accent: Color {
        loadedPlugin(at: selection)?.accent ?? Palette.critical
    }

    private func loadedPlugin(at index: Int) -> TabPlugin? {
        tabs.indices.contains(index) ? tabs[index].plugin : nil
    }

    /// The probe of launchd can take a moment, so it runs off the main thread and the button is
    /// disabled meanwhile so a second press cannot start two copies. A relaunch that succeeds
    /// ends this process; one that fails logs why and re-enables the button.
    private func relaunch() {
        isRelaunching = true
        DispatchQueue.global(qos: .userInitiated).async {
            Relauncher.relaunch(log: { NSLog("%@", $0) })
            DispatchQueue.main.async { isRelaunching = false }
        }
    }

    /// Tells the monitor which of its samplers the selected tab needs. Until every tab is a real
    /// plugin, that rule still lives in MonitorSamplingPlan, keyed by MonitorMode; an error tab
    /// or an empty list needs nothing, so the monitor is told the window is effectively hidden.
    private func present(index: Int, isVisible: Bool) {
        let plugin = loadedPlugin(at: index)
        plugin?.visibilityChanged(isVisible: isVisible)
        guard let backed = plugin as? MonitorBackedTab else {
            // The mode is ignored while nothing is visible; .memory is just a placeholder.
            monitor.updatePresentation(isVisible: false, mode: .memory)
            return
        }
        monitor.updatePresentation(isVisible: isVisible, mode: backed.monitorMode)
    }
}

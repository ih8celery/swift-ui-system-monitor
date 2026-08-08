import AppKit
import Foundation
import SwiftUI

struct RootView: View {
    @ObservedObject var monitor: UnifiedMonitor
    @State private var mode = MonitorMode.memory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28)

                Picker("Mode", selection: $mode) {
                    ForEach(MonitorMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon)
                            .help(mode.rawValue)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .labelsHidden()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit SystemBar")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().background(Color.white.opacity(0.08))

            Group {
                switch mode {
                case .power:
                    PowerPanel(monitor: monitor)
                case .developer:
                    DeveloperPanel(monitor: monitor)
                case .memory:
                    MemoryPanel(monitor: monitor)
                case .disk:
                    DiskPanel(monitor: monitor)
                case .network:
                    NetworkPanel(monitor: monitor)
                case .cpu:
                    CPUPanel(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 680)
        .background(Palette.background)
        .foregroundStyle(Palette.foreground)
        .onAppear {
            monitor.updatePresentation(isVisible: true, mode: mode)
        }
        .onDisappear {
            monitor.updatePresentation(isVisible: false, mode: mode)
        }
        .onChange(of: mode) { _, newMode in
            monitor.updatePresentation(isVisible: true, mode: newMode)
        }
    }

    private var accent: Color {
        switch mode {
        case .power: return Palette.caution
        case .developer: return Palette.purple
        case .memory: return Palette.good
        case .disk: return Palette.cyan
        case .network: return Palette.blue
        case .cpu: return Palette.warning
        }
    }
}



import AppKit
import Foundation
import SwiftUI

struct MemoryPanel: View {
    @ObservedObject var monitor: UnifiedMonitor

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(byteString(monitor.memory.available)) Available")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(memoryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 10) {
                    StatPill(label: "Swap", value: swapStatText(used: monitor.memory.swapUsed, total: monitor.memory.swapTotal))
                        .help("macOS grows this reserved amount dynamically as needed, so the total is what's currently set aside, not a fixed cap.")
                    StatPill(label: "Pressure", value: pressureText)
                }

                HStack(spacing: 10) {
                    Text("GPU")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(percentString(monitor.gpu.deviceUtilization))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.blue)
                    Spacer()
                    StatPill(label: "GPU in use", value: byteString(monitor.gpu.inUseMemory))
                }
                .padding(10)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                MemoryBar(memory: monitor.memory)
                    .frame(height: 34)

                MemoryLegend(memory: monitor.memory)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionTitle("Pressure History")
                        Spacer()
                        ChartUnitLabel("% pressure - recent")
                    }
                    Sparkline(values: monitor.pressureHistory, maxValue: 100, color: pressureColor, fill: true)
                        .frame(height: 100)
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(updatedAgoText(lastUpdated: monitor.lastUpdated, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 430)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            Divider().background(Color.white.opacity(0.08))

            ProcessList(
                title: "Top Memory",
                rows: monitor.topMemoryProcesses,
                value: { byteString($0.physical) },
                subvalue: { "\($0.count)x  \(percentString(machineCPUPercent($0.cpu))) CPU" },
                fraction: { row in
                    Double(row.physical) / Double(monitor.maxPhysicalProcessMemory)
                },
                color: Palette.good
            )
            .padding(16)
        }
    }

    private var memoryColor: Color {
        let ratio = Double(monitor.memory.available) / Double(max(monitor.memory.total, 1))
        if ratio > 0.30 && !memoryNeedsAction { return Palette.good }
        if ratio > 0.15 { return Palette.caution }
        return Palette.critical
    }

    private var pressureText: String {
        guard let pressure = monitor.pressure else { return "Unknown" }
        return "\(Int(pressure.rounded()))%"
    }

    private var pressureColor: Color {
        guard let pressure = monitor.pressure else { return .secondary }
        if pressure < 50 { return Palette.good }
        if pressure < 75 { return Palette.caution }
        return Palette.critical
    }

    private var memoryNeedsAction: Bool {
        let availableRatio = Double(monitor.memory.available) / Double(max(monitor.memory.total, 1))
        return availableRatio < 0.25 || monitor.memory.swapUsed > 1_073_741_824 || (monitor.pressure ?? 0) >= 75
    }

}


enum MemorySegmentKind: String, CaseIterable, Hashable {
    case active = "Active"
    case wired = "Wired"
    case compressed = "Compressed"
    case inactive = "Inactive"
    case free = "Free"
}

struct MemorySegment: Hashable {
    let kind: MemorySegmentKind
    let value: UInt64
}

/// Single source of truth for which memory categories are non-zero right now.
/// MemoryBar and MemoryLegend both draw from this so they can't drift apart:
/// every segment the bar can render also gets a name and value in the legend.
func memorySegments(for memory: MemorySnapshot) -> [MemorySegment] {
    [
        MemorySegment(kind: .active, value: memory.active),
        MemorySegment(kind: .wired, value: memory.wired),
        MemorySegment(kind: .compressed, value: memory.compressed),
        MemorySegment(kind: .inactive, value: memory.inactive),
        MemorySegment(kind: .free, value: memory.free + memory.purgeable)
    ].filter { $0.value > 0 }
}

func memorySegmentColor(_ kind: MemorySegmentKind) -> Color {
    switch kind {
    case .active: return Palette.blue
    case .wired: return Palette.critical
    case .compressed: return Palette.purple
    case .inactive: return Palette.caution
    case .free: return Palette.good
    }
}

private func memoryBarSegments(for memory: MemorySnapshot) -> [BarSegment] {
    memorySegments(for: memory).map {
        BarSegment(label: $0.kind.rawValue, value: $0.value, color: memorySegmentColor($0.kind))
    }
}

struct MemoryBar: View {
    let memory: MemorySnapshot

    var body: some View {
        SegmentedBar(segments: memoryBarSegments(for: memory), total: memory.total)
    }
}

struct MemoryLegend: View {
    let memory: MemorySnapshot

    var body: some View {
        SegmentedLegend(rows: memoryBarSegments(for: memory))
    }
}



import Foundation
import SwiftUI
import SystemBarKit

struct MemoryPanel: View {
    @ObservedObject var plugin: MemoryPlugin

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(byteString(plugin.stats.memory.available)) Available")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(memoryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .help(usedBreakdownText(memory: plugin.stats.memory))

                HStack(spacing: 10) {
                    StatPill(label: "Swap", value: swapStatText(used: plugin.stats.memory.swapUsed, total: plugin.stats.memory.swapTotal))
                        .help("macOS grows this reserved amount dynamically as needed, so the total is what's currently set aside, not a fixed cap.")
                    StatPill(label: "Pressure", value: pressureText)
                        .help("The kernel's own memory pressure level, the signal behind Activity Monitor's pressure graph. Warning means macOS has started compressing or swapping to keep up; Critical means it is struggling.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("GPU busy")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(percentString(plugin.stats.gpu.deviceUtilization))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.blue)
                        Spacer()
                    }
                    .help("How hard the GPU's compute units were working at the last 30-second check. It is not a memory figure.")

                    HStack(spacing: 10) {
                        StatPill(label: "GPU memory in use", value: byteString(plugin.stats.gpu.inUseMemory))
                        StatPill(label: "GPU memory allocated", value: byteString(plugin.stats.gpu.allocatedMemory))
                    }
                    .help("What the GPU driver is using now, and what it has set aside. The allocation is wired RAM that no process in the list owns, so it is part of the gap between used memory and the processes shown.")
                }
                .padding(10)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                MemoryBar(memory: plugin.stats.memory)
                    .frame(height: 34)

                MemoryLegend(memory: plugin.stats.memory)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(updatedAgoText(lastUpdated: plugin.stats.lastUpdated, now: context.date))
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
                rows: plugin.processes.topMemory,
                value: { byteString($0.physical) },
                subvalue: { "\($0.count)x  \(percentString(machineCPUPercent($0.cpu))) CPU" },
                fraction: { row in
                    Double(row.physical) / Double(plugin.processes.maxPhysical)
                },
                color: Palette.good
            )
            .padding(16)
        }
    }

    private var memoryColor: Color {
        let ratio = Double(plugin.stats.memory.available) / Double(max(plugin.stats.memory.total, 1))
        if ratio > 0.30 && !memoryNeedsAction { return Palette.good }
        if ratio > 0.15 { return Palette.caution }
        return Palette.critical
    }

    private var pressureText: String {
        plugin.stats.pressure?.label ?? "Unknown"
    }

    private var memoryNeedsAction: Bool {
        let availableRatio = Double(plugin.stats.memory.available) / Double(max(plugin.stats.memory.total, 1))
        let pressureIsRaised = (plugin.stats.pressure ?? .normal) != .normal
        return availableRatio < 0.25 || plugin.stats.memory.swapUsed > 1_073_741_824 || pressureIsRaised
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



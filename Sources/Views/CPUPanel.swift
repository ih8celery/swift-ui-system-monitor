import AppKit
import Foundation
import SwiftUI

struct CPUPanel: View {
    @ObservedObject var monitor: UnifiedMonitor
    @State private var drillGroup: String?
    @State private var drillRows: [ProcessDetail] = []
    @State private var isDrillLoading = false

    private let accentColor = Palette.warning

    private var cpuRows: [ProcessSnapshot] {
        monitor.topCPUProcesses
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(percentString(monitor.cpuUsagePercent)) CPU")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(headlineColor)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    StatPill(label: "Processes", value: "\(monitor.totalProcessCount)")
                }

                HStack {
                    SectionTitle("CPU History")
                    Spacer()
                    ChartUnitLabel("% CPU - last 90s")
                }
                Sparkline(values: monitor.cpuHistory, maxValue: 100, color: accentColor, fill: true)
                    .frame(height: 120)

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 300)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            Divider().background(Color.white.opacity(0.08))

            rightRegion
                .padding(16)
        }
    }

    @ViewBuilder
    private var rightRegion: some View {
        if let drillGroup {
            ProcessDetailView(
                groupName: drillGroup,
                rows: drillRows,
                isLoading: isDrillLoading,
                accent: accentColor,
                onBack: { self.drillGroup = nil }
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProcessList(
                    title: "Top CPU",
                    rows: cpuRows,
                    value: { percentString(machineCPUPercent($0.cpu)) },
                    subvalue: { "Memory \(byteString($0.physical))" },
                    fraction: { row in
                        ProcessCPUScale.barFraction(wholeMachinePercent: machineCPUPercent(row.cpu))
                    },
                    color: accentColor,
                    onTap: { drillInto($0) }
                )

                Text("Share of the whole machine · rolling average. The headline above is instantaneous, so the two use the same scale but won't match to the decimal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Snapshot per-PID detail for the tapped group off the main thread, then show it.
    private func drillInto(_ row: ProcessSnapshot) {
        drillGroup = row.name
        drillRows = []
        isDrillLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = UnifiedMonitor.fetchGroupDetail(name: row.name)
            DispatchQueue.main.async {
                guard drillGroup == row.name else { return }
                drillRows = rows
                isDrillLoading = false
            }
        }
    }

    private var cpuNeedsAction: Bool {
        monitor.cpuUsagePercent > 70 || machineCPUPercent(cpuRows.first?.cpu ?? 0) > 60
    }

    private var headlineColor: Color {
        cpuNeedsAction
            ? Palette.critical
            : Palette.warning
    }
}

struct ProcessList: View {
    let title: String
    let rows: [ProcessSnapshot]
    let value: (ProcessSnapshot) -> String
    let subvalue: (ProcessSnapshot) -> String
    let fraction: (ProcessSnapshot) -> Double
    let color: Color
    /// When set, each row becomes a tap target that drills into that group.
    var onTap: ((ProcessSnapshot) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title)
                Spacer()
                Text("\(rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        if let onTap {
                            Button { onTap(row) } label: { rowContent(row) }
                                .buttonStyle(.plain)
                        } else {
                            rowContent(row)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ row: ProcessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.count > 1 ? "\(row.name) (\(row.count))" : row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(value(row))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                ProgressBar(value: fraction(row), color: color)
                    .frame(height: 6)
                Text(subvalue(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .trailing)
            }
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Drill-in detail for a tapped process group. Replaces the list region inside
/// the popover; a back control returns to the list. Data is a snapshot taken at
/// tap time (see UnifiedMonitor.fetchGroupDetail), so it does not live-refresh.
struct ProcessDetailView: View {
    let groupName: String
    let rows: [ProcessDetail]
    let isLoading: Bool
    let accent: Color
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)

                Spacer()

                Text(rows.count == 1 ? "1 process" : "\(rows.count) processes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(groupName)
                .font(.system(size: 18, weight: .bold))
                .lineLimit(1)

            if !isLoading && !rows.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Likely:")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                    Text(ProcessClassifier.likelyLabel(for: rows))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("A best guess from the process's path, arguments, and parents. It may be wrong.")
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading process details…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
                Spacer()
            } else if rows.isEmpty {
                Text("These processes are no longer running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { detail in
                            ProcessDetailRow(detail: detail)
                        }
                    }
                }
            }
        }
    }
}

struct ProcessDetailRow: View {
    let detail: ProcessDetail

    private var ancestry: String {
        var chain = ["from \(detail.parentName)"]
        if !detail.grandparentName.isEmpty {
            chain.append(detail.grandparentName)
        }
        return chain.joined(separator: " ‹ ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("PID \(detail.pid)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text(percentString(detail.cpuPercent) + " CPU")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }

            Text(detail.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label(ancestry, systemImage: "arrow.turn.left.up")
                    .lineLimit(1)
                Spacer()
                Text("\(byteString(detail.memory)) · up \(detail.uptime)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(detail.path)
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}



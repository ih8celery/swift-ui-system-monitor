import Foundation
import SwiftUI
import SystemBarKit

struct CPUPanel: View {
    @ObservedObject var plugin: CPUPlugin
    @State private var drillGroup: String?
    @State private var drillRows: [ProcessDetail] = []
    @State private var isDrillLoading = false

    private let accentColor = Palette.warning

    private var cpuRows: [ProcessSnapshot] {
        plugin.processes.topCPU
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(percentString(plugin.fastStats.cpuUsagePercent)) CPU")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(headlineColor)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    StatPill(label: "Processes", value: "\(plugin.processes.totalCount)")
                }

                HStack {
                    SectionTitle("CPU History")
                    Spacer()
                    ChartUnitLabel("% CPU - last 90s")
                }
                Sparkline(values: plugin.fastStats.cpuHistory, maxValue: 100, color: accentColor, fill: true)
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
        // Take the plugin reference on main, so the background closure never reads view state.
        let plugin = plugin
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = plugin.groupDetail(named: row.name)
            DispatchQueue.main.async {
                guard drillGroup == row.name else { return }
                drillRows = rows
                isDrillLoading = false
            }
        }
    }

    private var cpuNeedsAction: Bool {
        plugin.fastStats.cpuUsagePercent > 70 || machineCPUPercent(cpuRows.first?.cpu ?? 0) > 60
    }

    private var headlineColor: Color {
        cpuNeedsAction
            ? Palette.critical
            : Palette.warning
    }
}

/// Drill-in detail for a tapped process group. Replaces the list region inside
/// the popover; a back control returns to the list. Data is a snapshot taken at
/// tap time (see ProcessDetail.fetchGroupDetail), so it does not live-refresh.
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
                // String(pid) rather than the Int32: SwiftUI Text groups integers by locale, which
                // renders pid 3390 as "3,390".
                Text("PID \(String(detail.pid))")
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



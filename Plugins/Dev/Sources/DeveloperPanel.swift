import Foundation
import SwiftUI
import SystemBarKit

/// The Dev tab: how much room the machine has left, and which projects are using it.
struct DeveloperPanel: View {
    @ObservedObject var plugin: DevPlugin

    private var capacity: CapacitySnapshot { plugin.capacity }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                headline

                HStack(spacing: 10) {
                    StatPill(label: "CPU", value: percentString(capacity.cpuBusyPercent ?? 0))
                    StatPill(label: "Thermal", value: capacity.thermalState)
                    StatPill(
                        label: "Projects",
                        value: "\(capacity.projectCount)"
                    )
                }

                SectionTitle("Projects drawing capacity")

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if capacity.rows.isEmpty {
                            EvidenceRow(
                                label: "No expensive work",
                                value: "Idle",
                                detail: "No builds, simulators, test runs, bundlers or automation are running."
                            )
                        }
                        ForEach(capacity.projectRows) { row in
                            ProjectLoadRow(row: row)
                        }
                        if let unattributed = capacity.unattributedRow {
                            Divider().background(Color.white.opacity(0.08)).padding(.vertical, 4)
                            ProjectLoadRow(row: unattributed)
                        }
                    }
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(capacity.health == .ok ? .secondary : Palette.warning)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Listening ports")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if capacity.ports.isEmpty {
                            EvidenceRow(
                                label: "Ports",
                                value: "None",
                                detail: "Nothing is listening on a TCP port."
                            )
                        }
                        ForEach(capacity.portsByProject, id: \.project) { group in
                            SectionTitle(group.project)
                                .padding(.top, 4)
                            ForEach(group.ports) { port in
                                DeveloperPortRow(port: port)
                            }
                        }
                        if !capacity.unattributedPorts.isEmpty {
                            SectionTitle("Other")
                                .padding(.top, 8)
                            ForEach(capacity.unattributedPorts) { port in
                                DeveloperPortRow(port: port)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 330)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The one line a reader acts on. It grades on whole-machine signals, so it stays meaningful
    /// even when every row below says its load could not be measured.
    private var headline: some View {
        Group {
            if let assessment = capacity.assessment {
                Text("Capacity: \(assessment.availableCapacity.label)")
                    .foregroundStyle(color(for: assessment.availableCapacity))
            } else {
                Text("Measuring…")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 32, weight: .bold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var statusText: String {
        guard let lastUpdated = capacity.lastUpdated else { return capacity.status }
        return "\(capacity.status) - \(relativeTimeString(lastUpdated)) ago"
    }

    private func color(for capacity: AvailableCapacity) -> Color {
        switch capacity {
        case .high: return Palette.good
        case .moderate: return Palette.caution
        case .low: return Palette.critical
        }
    }
}


/// One project's draw on the machine. Numbers here are measured or absent — the row never shows a
/// zero standing in for a failed sample.
struct ProjectLoadRow: View {
    let row: ProjectWorkRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(row.project == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Text(headlineFigure)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(row.project == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text(categoryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if case .measured(let cpuPercent, _, _, _, _, _) = row.load {
                ProgressBar(
                    value: ProcessCPUScale.barFraction(wholeMachinePercent: cpuPercent),
                    color: row.project == nil ? Palette.purple.opacity(0.5) : Palette.purple
                )
                .frame(height: 6)
            }

            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var headlineFigure: String {
        switch row.load {
        case .measured(let cpuPercent, _, _, _, _, _):
            return percentString(cpuPercent)
        case .unavailable:
            return "not measurable"
        }
    }

    private var categoryText: String {
        row.categories
            .map { $0.count > 1 ? "\($0.category.label) x\($0.count)" : $0.category.label }
            .joined(separator: " - ")
    }

    /// Says how much of the project was actually sampled. A build churning through short-lived
    /// compiler jobs can only ever be partly seen, so the row discloses that rather than implying
    /// its figures are a total.
    private var detailText: String {
        switch row.load {
        case .measured(_, let memory, let readRate, let writeRate, let sampled, let total):
            let io = "\(rateString(readRate)) read, \(rateString(writeRate)) write"
            guard sampled == total else {
                return "\(byteString(memory)) - \(io) - \(sampled) of \(total) processes sampled"
            }
            return "\(byteString(memory)) - \(io)"
        case .unavailable:
            // Two different reasons, and the reader deserves the right one.
            guard row.categories.contains(where: { !$0.category.isMeasurable }) else {
                return "Load not measurable: these processes ended before they could be sampled twice."
            }
            return "A build's compile jobs are replaced faster than they can be measured. The CPU figure at the top covers the whole machine."
        }
    }
}


struct DeveloperPortRow: View {
    let port: DeveloperPort

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(port.process)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(port.port)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            // String(pid) rather than interpolating the Int: SwiftUI Text applies locale grouping to
            // integers, which turns pid 3390 into "3,390".
            Text("\(port.localAddress) - pid \(String(port.pid))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

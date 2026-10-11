import AppKit
import Foundation
import SwiftUI
import SystemBarKit

enum DiskListMode: String, CaseIterable, Identifiable {
    case biggest = "Biggest"
    case movers = "Movers"
    var id: String { rawValue }
}

enum DiskMoverWindow: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"
    var id: String { rawValue }
}

struct DiskPanel: View {
    @ObservedObject var plugin: DiskPlugin
    @State private var mode = DiskListMode.biggest
    @State private var window = DiskMoverWindow.day
    @State private var showsSimulators = false

    private var snapshot: DiskSnapshot { plugin.snapshot }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .padding(18)
                .frame(width: 430)
                .frame(maxHeight: .infinity, alignment: .topLeading)

            Divider().background(Color.white.opacity(0.08))

            rightColumn
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Left: capacity and distribution

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(headlineText)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(headlineColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 10) {
                StatPill(label: "Snapshots", value: "\(snapshot.localSnapshotCount)")
                if let boot = snapshot.boot {
                    StatPill(label: "Used", value: byteString(boot.used))
                    StatPill(label: "Capacity", value: byteString(boot.total))
                }
            }

            if let boot = snapshot.boot {
                SegmentedBar(segments: capacityRows(for: boot).filter { $0.value > 0 }, total: boot.total)
                    .frame(height: 34)
                SegmentedLegend(rows: capacityRows(for: boot))

                SectionTitle("Where the space is")
                let distribution = DiskRows.distribution(biggest: snapshot.biggest, volume: boot, homeDirectory: plugin.homeDirectory)
                SegmentedBar(segments: distribution.filter { $0.value > 0 }, total: boot.total)
                    .frame(height: 20)
                SegmentedLegend(rows: distribution)
            }

            if !snapshot.otherVolumes.isEmpty {
                SectionTitle("Other Volumes")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.otherVolumes) { volume in
                            EvidenceRow(
                                label: volume.name,
                                value: "\(byteString(volume.free)) free",
                                detail: "\(byteString(volume.used)) used of \(byteString(volume.total))"
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text(snapshot.status)
                .font(.caption)
                .foregroundStyle(snapshot.health == .ok ? .secondary : Palette.warning)
        }
    }

    private var headlineText: String {
        guard let boot = snapshot.boot else { return "Reading volumes" }
        return "\(byteString(boot.free)) Free"
    }

    private var headlineColor: Color {
        guard let boot = snapshot.boot else { return .secondary }
        if boot.freeRatio > 0.20 { return Palette.good }
        if boot.freeRatio > 0.10 { return Palette.caution }
        return Palette.critical
    }

    // MARK: - Right: biggest and movers

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle("Where it goes")
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(DiskListMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                if mode == .movers {
                    Picker("Window", selection: $window) {
                        ForEach(DiskMoverWindow.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 90)
                }
            }

            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        switch mode {
                        case .biggest:
                            biggestRows(now: context.date)
                        case .movers:
                            moverRows(now: context.date)
                        }
                    }
                }
            }

            footer
        }
    }

    @ViewBuilder
    private func biggestRows(now: Date) -> some View {
        let rows = snapshot.biggest
        let top = rows.first?.bytes ?? 1
        if rows.isEmpty {
            Text(snapshot.isScanning ? "Measuring…" : "No folders measured yet. Press rescan, or wait for the first background scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
            DiskRowView(row: row, fraction: Double(row.bytes) / Double(max(top, 1)), change: nil, now: now, homeDirectory: plugin.homeDirectory)
                .onTapGesture { if row.kind == .simulatorGroup { showsSimulators.toggle() } }
            if row.kind == .simulatorGroup, showsSimulators {
                ForEach(snapshot.simulators) { device in
                    DiskRowView(row: device, fraction: Double(device.bytes) / Double(max(row.bytes, 1)), change: nil, now: now, homeDirectory: plugin.homeDirectory)
                        .padding(.leading, 18)
                }
            }
        }
    }

    @ViewBuilder
    private func moverRows(now: Date) -> some View {
        let movers = window == .day ? snapshot.movers24h : snapshot.movers7d
        let top = movers.first?.magnitude ?? 1
        if movers.isEmpty {
            Text("Nothing changed in the last \(window.rawValue), or there is no earlier scan to compare with yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(movers) { mover in
            DiskRowView(row: mover.row, fraction: Double(mover.magnitude) / Double(max(top, 1)), change: mover.change, now: now, homeDirectory: plugin.homeDirectory)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(footerText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(snapshot.settingsProblem == nil && snapshot.saveProblem == nil && snapshot.ledgerNote == nil ? .secondary : Palette.warning)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            Spacer()
            Button {
                plugin.requestScan(force: true)
            } label: {
                if snapshot.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(snapshot.isScanning)
            .help("Measure every folder again now")
        }
    }

    /// Problems first, then what is running, then each plan's age.
    private func footerText(now: Date) -> String {
        if let problem = snapshot.settingsProblem { return problem }
        if let problem = snapshot.saveProblem { return problem }
        if let note = snapshot.ledgerNote { return note }
        if snapshot.isScanning { return snapshot.scanStatus }
        let ages = DiskPlanKind.allCases.map { kind -> String in
            guard let date = snapshot.planAges[kind] else { return "\(kind.title) never" }
            return "\(kind.title) \(relativeTimeString(date, now: now)) ago"
        }
        return ages.joined(separator: " · ")
    }
}

/// The two capacity buckets. The legend shows both even when one is zero; the bar filters those
/// out itself, since it cannot draw a zero-width segment meaningfully.
private func capacityRows(for volume: DiskVolume) -> [BarSegment] {
    [
        BarSegment(label: "Used", value: volume.used, color: Palette.blue),
        BarSegment(label: "Free", value: volume.free, color: Palette.good)
    ]
}

import AppKit
import Foundation
import SwiftUI
import SystemBarKit

struct DiskPanel: View {
    @ObservedObject var plugin: DiskPlugin

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(headlineText)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(headlineColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 10) {
                    StatPill(label: "Purgeable", value: byteString(plugin.snapshot.boot?.purgeable ?? 0))
                    StatPill(label: "Snapshots", value: "\(plugin.snapshot.localSnapshotCount)")
                    StatPill(label: "Cleanup", value: byteString(plugin.snapshot.reclaimableTotal))
                }

                if let boot = plugin.snapshot.boot {
                    CapacityBar(volume: boot)
                        .frame(height: 34)

                    CapacityLegend(volume: boot)
                }

                if !plugin.snapshot.otherVolumes.isEmpty {
                    SectionTitle("Other Volumes")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(plugin.snapshot.otherVolumes) { volume in
                                EvidenceRow(
                                    label: volume.name,
                                    value: byteString(volume.importantAvailable),
                                    detail: "\(byteString(volume.used)) used of \(byteString(volume.total))"
                                )
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                Text(plugin.snapshot.status)
                    .font(.caption)
                    .foregroundStyle(plugin.snapshot.health == .ok ? .secondary : Palette.warning)
            }
            .padding(18)
            .frame(width: 430)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            Divider().background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionTitle("Reclaimable Space")
                    Spacer()
                    Button {
                        plugin.scanHogs(force: true)
                    } label: {
                        if plugin.snapshot.isScanningHogs {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(plugin.snapshot.isScanningHogs)
                    .help("Rescan reclaimable paths")
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plugin.snapshot.hogs) { hog in
                            DiskHogRow(hog: hog, fraction: Double(hog.size) / Double(plugin.snapshot.maxHogSize))
                        }
                    }
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(hogFooterText(now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var headlineText: String {
        guard let boot = plugin.snapshot.boot else { return "Reading volumes" }
        return "\(byteString(boot.importantAvailable)) Available"
    }

    private var headlineColor: Color {
        guard let boot = plugin.snapshot.boot else { return .secondary }
        if boot.availableRatio > 0.20 { return Palette.good }
        if boot.availableRatio > 0.10 { return Palette.caution }
        return Palette.critical
    }

    private func hogFooterText(now: Date) -> String {
        guard let lastScan = plugin.snapshot.lastHogScan else { return plugin.snapshot.hogStatus }
        return "\(plugin.snapshot.hogStatus) - \(relativeTimeString(lastScan, now: now)) ago"
    }
}

struct DiskHogRow: View {
    let hog: DiskHog
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(hog.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(byteString(hog.size))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            ProgressBar(value: fraction, color: Palette.cyan)
                .frame(height: 4)
            Text(hog.hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The three capacity buckets, unfiltered — CapacityLegend shows all of them even when a
/// bucket is zero, while CapacityBar (which can't draw a zero-width segment meaningfully)
/// filters those out itself.
private func capacityRows(for volume: DiskVolume) -> [BarSegment] {
    [
        BarSegment(label: "Used", value: volume.used, color: Palette.blue),
        BarSegment(label: "Purgeable", value: volume.purgeable, color: Palette.caution),
        BarSegment(label: "Free", value: volume.free, color: Palette.good)
    ]
}

struct CapacityBar: View {
    let volume: DiskVolume

    var body: some View {
        SegmentedBar(segments: capacityRows(for: volume).filter { $0.value > 0 }, total: volume.total)
    }
}

struct CapacityLegend: View {
    let volume: DiskVolume

    var body: some View {
        SegmentedLegend(rows: capacityRows(for: volume) + [BarSegment(label: "Capacity", value: volume.total, color: Color.white.opacity(0.35))])
    }
}



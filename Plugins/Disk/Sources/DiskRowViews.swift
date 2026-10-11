import Foundation
import SwiftUI
import SystemBarKit

/// One row of the right-hand list: name and size (or signed change), a bar relative to the top
/// row, the shortened path, and the age of the measurement. A simulator device adds its last boot.
struct DiskRowView: View {
    let row: DiskRow
    let fraction: Double
    let change: DiskMover.Change?
    let now: Date
    let homeDirectory: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if row.kind == .simulatorGroup {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(valueColor)
            }
            ProgressBar(value: fraction, color: barColor)
                .frame(height: 4)
            HStack {
                Text(detailText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("measured \(relativeTimeString(row.measuredAt, now: now)) ago")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var valueText: String {
        switch change {
        case .grew(let bytes)?: return "+\(byteString(bytes)) → \(byteString(row.bytes))"
        case .shrank(let bytes)?: return "−\(byteString(bytes)) → \(byteString(row.bytes))"
        case .freed(let bytes)?: return "freed \(byteString(bytes))"
        case .new?: return "new \(byteString(row.bytes))"
        case nil: return byteString(row.bytes)
        }
    }

    private var valueColor: Color {
        switch change {
        case .grew?, .new?: return Palette.warning
        case .shrank?, .freed?: return Palette.good
        case nil: return Palette.foreground
        }
    }

    private var barColor: Color {
        switch change {
        case .grew?, .new?: return Palette.warning
        case .shrank?, .freed?: return Palette.good
        case nil: return Palette.cyan
        }
    }

    private var detailText: String {
        let path = DiskRows.displayPath(row.path, homeDirectory: homeDirectory)
        guard let simulator = row.simulator else { return path }
        guard let booted = simulator.lastBootedAt else { return "never booted · \(path)" }
        return "last booted \(relativeTimeString(booted, now: now)) ago · \(path)"
    }
}

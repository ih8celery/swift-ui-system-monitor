import SwiftUI

/// A labeled slice of a SegmentedBar/SegmentedLegend pair — e.g. one memory category or one
/// disk capacity bucket.
public struct BarSegment: Identifiable, Hashable, Sendable {
    public let label: String
    public let value: UInt64
    public let color: Color

    public var id: String { label }

    public init(label: String, value: UInt64, color: Color) {
        self.label = label
        self.value = value
        self.color = color
    }
}

/// Proportional horizontal bar shared by MemoryBar and CapacityBar: each segment's width is
/// its share of `total`.
public struct SegmentedBar: View {
    let segments: [BarSegment]
    let total: UInt64

    public init(segments: [BarSegment], total: UInt64) {
        self.segments = segments
        self.total = total
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    segment.color
                        .frame(width: max(2, geometry.size.width * CGFloat(Double(segment.value) / Double(max(total, 1)))))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(Color.white.opacity(0.08))
        }
    }
}

/// Two-column legend shared by MemoryLegend and CapacityLegend: a colored dot, label, and
/// byte value per row.
public struct SegmentedLegend: View {
    let rows: [BarSegment]

    public init(rows: [BarSegment]) {
        self.rows = rows
    }

    public var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 8, height: 8)
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(byteString(row.value))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .font(.caption)
            }
        }
    }
}

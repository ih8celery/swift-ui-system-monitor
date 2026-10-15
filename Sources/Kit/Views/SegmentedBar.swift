import SwiftUI

/// A labeled slice of a SegmentedBar/SegmentedLegend pair — e.g. one memory category or one
/// disk capacity bucket.
public struct BarSegment: Identifiable, Hashable, Sendable {
    /// The slice's name in the legend, e.g. "Wired". Also its identity, so labels in one bar
    /// must differ.
    public let label: String
    /// The slice's size in bytes: the bar sizes it against the bar's total, and the legend
    /// prints it with the formatter it was given, `byteString(_:)` unless told otherwise.
    public let value: UInt64
    /// The slice's fill in the bar and its dot in the legend.
    public let color: Color

    /// The label, which is why labels in one bar must differ.
    public var id: String { label }

    /// A slice of `value` bytes, drawn in `color` and named `label`.
    public init(label: String, value: UInt64, color: Color) {
        self.label = label
        self.value = value
        self.color = color
    }
}

/// A proportional horizontal bar, e.g. memory by category or a disk by used and free: each
/// segment's width is its share of `total`, drawn left to right in the order given. A segment
/// never gets narrower than 2 points, so leave out zero-sized ones. Pair it with a
/// `SegmentedLegend` built from the same segments.
public struct SegmentedBar: View {
    let segments: [BarSegment]
    let total: UInt64

    /// `total` is the whole the segments are shares of, in the same units as their values; it
    /// may exceed their sum, which leaves the rest of the bar empty.
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

/// A two-column legend for a `SegmentedBar`: a colored dot, the label, and the value as bytes
/// per row. It shows every row it is given, zero-sized ones included.
public struct SegmentedLegend: View {
    let rows: [BarSegment]
    let format: (UInt64) -> String

    /// One legend row per segment, in the order given, each value printed with
    /// `byteString(_:)`. Use `init(rows:format:)` to match the units the rest of a tab shows.
    public init(rows: [BarSegment]) {
        self.init(rows: rows, format: byteString)
    }

    /// One legend row per segment, in the order given, each value printed with `format`: pass
    /// the formatter the rest of the tab uses, e.g. `fileByteString` for a disk's sizes or
    /// `memoryByteString` for memory, so the legend reads the same as the numbers beside it.
    public init(rows: [BarSegment], format: @escaping (UInt64) -> String) {
        self.rows = rows
        self.format = format
    }

    /// What the legend prints for `row`. Package-only, for tests.
    package func valueText(_ row: BarSegment) -> String {
        format(row.value)
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
                    Text(valueText(row))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .font(.caption)
            }
        }
    }
}

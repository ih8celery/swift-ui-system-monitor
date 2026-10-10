import Foundation
import SwiftUI

/// A card for one finding: a bold label on the left, a short monospaced value on the right,
/// and up to two lines of detail beneath, e.g. a sleep assertion and the process holding it.
public struct EvidenceRow: View {
    let label: String
    let value: String
    let detail: String

    /// - Parameters:
    ///   - label: What the finding is about; one line, truncated if long.
    ///   - value: A short verdict or figure; one line, shrunk to fit.
    ///   - detail: The evidence behind it, in secondary text; at most two lines.
    public init(label: String, value: String, detail: String) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A headline figure in large coloured type under a small caption, e.g. "Down" over the current
/// download rate. It fills the width it is given, so two side by side split a row evenly.
public struct RateCard: View {
    let title: String
    let value: String
    let color: Color

    /// `value` is already-formatted text, such as `rateString(_:)` returns; `color` tints it.
    public init(title: String, value: String, color: Color) {
        self.title = title
        self.value = value
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A small rounded chip showing a label and a value on one line, e.g. "Swap 1.2 GB", for the row
/// of quick facts at the top of a tab.
public struct StatPill: View {
    let label: String
    let value: String

    /// The label is drawn in secondary text, the value after it in monospaced type.
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A section heading inside a tab, drawn small, bold and in capitals.
public struct SectionTitle: View {
    let text: String

    /// The heading as written; the view upper-cases it.
    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.78))
            .textCase(.uppercase)
    }
}

/// A small monospaced caption saying what a chart's values are and over what span, e.g.
/// "% CPU - last 90s". It usually sits on the right of a chart's `SectionTitle`.
public struct ChartUnitLabel: View {
    let text: String

    /// The caption as written.
    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

/// One chart legend entry: a coloured dot and a caption, e.g. the download line's colour and
/// "Download".
public struct LegendLabel: View {
    let text: String
    let color: Color

    /// A dot of `color` followed by `text`.
    public init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A thin capsule bar filled from the left, over a faint track. It takes the size its container
/// gives it, so set a height with `.frame(height:)`.
public struct ProgressBar: View {
    let value: Double
    let color: Color

    /// `value` is how full the bar is, from 0 to 1; anything outside that range is clamped.
    public init(value: Double, color: Color) {
        self.value = value
        self.color = color
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(1, value))))
            }
        }
    }
}

/// A line chart of a short history on a rounded card, oldest value on the left. It draws
/// nothing until there are at least two values, and takes the size its container gives it.
public struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    let color: Color
    let fill: Bool

    /// - Parameters:
    ///   - values: The history, oldest first, spread evenly across the width.
    ///   - maxValue: The value that reaches the top edge; higher values are clipped to it, and
    ///     anything below 1 is treated as 1.
    ///   - fill: Whether to shade the area under the line with a faint wash of `color`.
    public init(values: [Double], maxValue: Double, color: Color, fill: Bool) {
        self.values = values
        self.maxValue = maxValue
        self.color = color
        self.fill = fill
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.055))

                if values.count > 1 {
                    sparklinePath(in: geometry.size)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                    if fill {
                        sparklineFillPath(in: geometry.size)
                            .fill(color.opacity(0.22))
                    }
                }
            }
        }
    }

    private func point(for value: Double, index: Int, size: CGSize) -> CGPoint {
        let x = size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
        let y = size.height - (size.height * CGFloat(max(0, min(1, value / max(maxValue, 1)))))
        return CGPoint(x: x, y: y)
    }

    private func sparklinePath(in size: CGSize) -> Path {
        Path { path in
            guard !values.isEmpty else { return }
            path.move(to: point(for: values[0], index: 0, size: size))
            for index in values.indices.dropFirst() {
                path.addLine(to: point(for: values[index], index: index, size: size))
            }
        }
    }

    private func sparklineFillPath(in size: CGSize) -> Path {
        Path { path in
            guard !values.isEmpty else { return }
            path.move(to: CGPoint(x: 0, y: size.height))
            for index in values.indices {
                path.addLine(to: point(for: values[index], index: index, size: size))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}

/// Two histories on one sparkline card with a shared scale, e.g. download and upload rates. The
/// scale's top is the larger of the two histories' peaks, and `first` is drawn filled beneath
/// `second`'s plain line.
public struct DualSparkline: View {
    let first: [Double]
    let second: [Double]
    let firstColor: Color
    let secondColor: Color

    /// Each history is oldest first, as for `Sparkline`.
    public init(first: [Double], second: [Double], firstColor: Color, secondColor: Color) {
        self.first = first
        self.second = second
        self.firstColor = firstColor
        self.secondColor = secondColor
    }

    private var maxValue: Double {
        max(first.max() ?? 1, second.max() ?? 1, 1)
    }

    public var body: some View {
        ZStack {
            Sparkline(values: first, maxValue: maxValue, color: firstColor, fill: true)
            Sparkline(values: second, maxValue: maxValue, color: secondColor, fill: false)
        }
    }
}


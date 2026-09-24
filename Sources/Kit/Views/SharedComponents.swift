import AppKit
import Foundation
import SwiftUI

struct EvidenceRow: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
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


struct RateCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
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

struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
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

struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.78))
            .textCase(.uppercase)
    }
}

struct ChartUnitLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

struct LegendLabel: View {
    let text: String
    let color: Color

    var body: some View {
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

struct ProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
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

struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    let color: Color
    let fill: Bool

    var body: some View {
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

struct DualSparkline: View {
    let first: [Double]
    let second: [Double]
    let firstColor: Color
    let secondColor: Color

    private var maxValue: Double {
        max(first.max() ?? 1, second.max() ?? 1, 1)
    }

    var body: some View {
        ZStack {
            Sparkline(values: first, maxValue: maxValue, color: firstColor, fill: true)
            Sparkline(values: second, maxValue: maxValue, color: secondColor, fill: false)
        }
    }
}



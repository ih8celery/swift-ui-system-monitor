import SwiftUI

/// A titled, scrolling list of process groups: a value on the right, a bar, and a second line.
/// Public because the Memory and CPU tabs both show one, and two bundles can share a view only
/// through the SDK.
public struct ProcessList: View {
    let title: String
    let rows: [ProcessSnapshot]
    let value: (ProcessSnapshot) -> String
    let subvalue: (ProcessSnapshot) -> String
    let fraction: (ProcessSnapshot) -> Double
    let color: Color
    /// When set, each row becomes a tap target that drills into that group.
    let onTap: ((ProcessSnapshot) -> Void)?

    public init(
        title: String,
        rows: [ProcessSnapshot],
        value: @escaping (ProcessSnapshot) -> String,
        subvalue: @escaping (ProcessSnapshot) -> String,
        fraction: @escaping (ProcessSnapshot) -> Double,
        color: Color,
        onTap: ((ProcessSnapshot) -> Void)? = nil
    ) {
        self.title = title
        self.rows = rows
        self.value = value
        self.subvalue = subvalue
        self.fraction = fraction
        self.color = color
        self.onTap = onTap
    }

    public var body: some View {
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

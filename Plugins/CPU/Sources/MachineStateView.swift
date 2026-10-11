import SwiftUI
import SystemBarKit

/// The left column under the history: one bar per cluster (or one thin bar per core when the
/// clusters are unknown), the user/system split, the load average against the core count, and
/// the thermal line when it has something to say.
struct MachineStateView: View {
    let clusters: [CPUCluster]?
    let fastStats: FastStatsSnapshot
    let state: MachineState
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let clusters {
                ForEach(clusters, id: \.name) { cluster in
                    LabelledBar(
                        label: "\(cluster.name) · \(cluster.coreCount)",
                        percent: cluster.usage(perCore: fastStats.perCoreUsage),
                        color: accent
                    )
                }
            } else {
                PerCoreBars(perCore: fastStats.perCoreUsage, color: accent)
            }

            UserSystemBar(user: fastStats.cpuUserPercent, system: fastStats.cpuSystemPercent, accent: accent)

            if state.coreCount > 0 {
                Text("load \(String(format: "%.1f", state.loadAverage)) of \(state.coreCount) cores")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !state.thermal.isNominal {
                ThermalLine(thermal: state.thermal)
            }
        }
    }
}

/// A name on the left, a thin bar, and the percent on the right.
struct LabelledBar: View {
    let label: String
    let percent: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            ProgressBar(value: percent / 100, color: color)
                .frame(height: 6)
            Text(percentString(percent))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// The fallback when sysctl's clusters cannot be laid over the cores: one thin bar per core,
/// in the kernel's order, with no names.
struct PerCoreBars: View {
    let perCore: [Double]
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(perCore.enumerated()), id: \.offset) { _, percent in
                ProgressBar(value: percent / 100, color: color)
                    .frame(height: 6)
            }
        }
    }
}

/// User time filled from the left in the accent, system time after it in white, idle as the
/// track, with a legend that names both figures.
struct UserSystemBar: View {
    let user: Double
    let system: Double
    let accent: Color

    private let systemColor = Color.white.opacity(0.6)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    accent.frame(width: geometry.size.width * fraction(user))
                    systemColor.frame(width: geometry.size.width * fraction(system))
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 6)

            HStack(spacing: 12) {
                LegendLabel(text: "user \(percentString(user))", color: accent)
                LegendLabel(text: "system \(percentString(system))", color: systemColor)
            }
        }
    }

    private func fraction(_ percent: Double) -> CGFloat {
        CGFloat(max(0, min(1, percent / 100)))
    }
}

/// "thermal: fair, 80% speed", coloured by the state the way the Power tab colours it.
struct ThermalLine: View {
    let thermal: ThermalReading

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var text: String {
        let state = thermalStateLabel(thermal.state).lowercased()
        if let limit = thermal.speedLimitPercent, limit < 100 {
            return "thermal: \(state), \(limit)% speed"
        }
        return "thermal: \(state)"
    }

    private var color: Color {
        switch thermal.state {
        case .critical: return Palette.critical
        case .serious: return Palette.warning
        default: return Palette.caution
        }
    }
}

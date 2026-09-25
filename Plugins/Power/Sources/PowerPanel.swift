import AppKit
import Foundation
import SwiftUI
import SystemBarKit

struct PowerPanel: View {
    @ObservedObject var plugin: PowerPlugin

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(plugin.snapshot.thermalState)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(thermalColor)

                HStack(spacing: 10) {
                    StatPill(label: "Source", value: plugin.snapshot.powerSource)
                    if let percent = plugin.snapshot.batteryPercent {
                        StatPill(label: "Battery", value: batteryStatLabel(percent: percent, isCharging: plugin.snapshot.isCharging))
                    }
                }

                SectionTitle("Sleep Assertions")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if plugin.snapshot.sleepAssertions.isEmpty {
                            EvidenceRow(label: "Sleep", value: "No blockers", detail: "pmset did not report active preventing assertions.")
                        }
                        ForEach(Array(plugin.snapshot.sleepAssertions.enumerated()), id: \.offset) { _, assertion in
                            EvidenceRow(label: "Assertion", value: "Active", detail: assertion)
                        }
                    }
                }

                Text(plugin.snapshot.status)
                    .font(.caption)
                    .foregroundStyle(plugin.snapshot.health == .ok ? .secondary : Palette.warning)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Likely Contributors")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plugin.snapshot.contributors) { contributor in
                            EvidenceRow(label: contributor.name, value: "Activity", detail: contributor.evidence)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 315)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var thermalColor: Color {
        switch plugin.snapshot.thermalState.lowercased() {
        case "critical": return Palette.critical
        case "serious": return Palette.warning
        case "fair": return Palette.caution
        default: return Palette.good
        }
    }
}

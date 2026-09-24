import Foundation
import SwiftUI
import SystemBarKit

/// Shown in place of a tab whose plugins.json entry could not be loaded. The point is that a
/// typo in the file is visible in the app, not in a log nobody opens.
struct ErrorTabView: View {
    let location: String
    let reason: String
    let configPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This tab could not be loaded")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.critical)
            EvidenceRow(label: "Entry", value: location, detail: reason)
            EvidenceRow(label: "Config", value: "plugins.json", detail: configPath)
            Text("Fix the entry, then press Relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Shown when plugins.json lists nothing enabled.
struct NoTabsView: View {
    let configPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No tabs are enabled")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            EvidenceRow(label: "Config", value: "plugins.json", detail: configPath)
            Text("Add or enable an entry, then press Relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

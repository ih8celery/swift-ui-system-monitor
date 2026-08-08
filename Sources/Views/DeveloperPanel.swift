import AppKit
import Foundation
import SwiftUI

struct DeveloperPanel: View {
    @ObservedObject var monitor: UnifiedMonitor

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(monitor.developer.ports.count) Listening Port\(monitor.developer.ports.count == 1 ? "" : "s")")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .lineLimit(1)

                HStack(spacing: 10) {
                    StatPill(label: "Dev Processes", value: "\(monitor.developer.processes.count)")
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(monitor.developer.ports) { port in
                            DeveloperPortRow(port: port)
                        }
                    }
                }

                Text(monitor.developer.status)
                    .font(.caption)
                    .foregroundStyle(monitor.developer.health == .ok ? .secondary : Palette.warning)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Toolchains")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(monitor.developer.processes) { process in
                            EvidenceRow(label: process.name, value: process.kind, detail: "\(percentString(process.cpu)) CPU, \(byteString(process.memory)), \(rateString(process.networkRate)) network")
                        }
                        if !monitor.developer.optionalServices.isEmpty {
                            SectionTitle("Available Integrations")
                                .padding(.top, 8)
                        }
                        ForEach(monitor.developer.optionalServices, id: \.self) { service in
                            EvidenceRow(label: "Optional", value: service, detail: "Detected without requiring integration commands.")
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 330)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}


struct DeveloperPortRow: View {
    let port: DeveloperPort

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(port.process)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(port.port)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            Text("\(port.localAddress) - pid \(port.pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}



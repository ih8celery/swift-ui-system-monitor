import Foundation
import SwiftUI
import SystemBarKit

struct NetworkPanel: View {
    @ObservedObject var plugin: NetworkPlugin

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RateCard(title: "Down", value: rateString(plugin.fastStats.currentDownloadRate), color: Palette.blue)
                    RateCard(title: "Up", value: rateString(plugin.fastStats.currentUploadRate), color: Palette.tangerine)
                }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    ChartUnitLabel("B/s - last 90s")
                }

                DualSparkline(
                    first: plugin.fastStats.downloadHistory,
                    second: plugin.fastStats.uploadHistory,
                    firstColor: Palette.blue,
                    secondColor: Palette.tangerine
                )
                .frame(height: hasBandwidthRows ? 92 : 110)

                HStack(spacing: 12) {
                    LegendLabel(text: "Download", color: Palette.blue)
                    LegendLabel(text: "Upload", color: Palette.tangerine)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SectionTitle("Speed Test")
                        Spacer()
                        Text(plugin.speedTest.status)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(plugin.speedTest.health == .degraded ? Palette.warning : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Button {
                            plugin.runSpeedTest()
                        } label: {
                            if plugin.speedTest.isRunning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "gauge.with.dots.needle.67percent")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(plugin.speedTest.isRunning)
                        .help("Run networkQuality speed test")
                    }

                    HStack(spacing: 10) {
                        SpeedTestMetric(label: "Test Down", value: speedTestRateText(plugin.speedTest.result?.downloadMbps), color: Palette.blue)
                        SpeedTestMetric(label: "Test Up", value: speedTestRateText(plugin.speedTest.result?.uploadMbps), color: Palette.tangerine)
                        SpeedTestMetric(label: "Latency", value: speedTestLatencyText(plugin.speedTest.result?.latencyMS), color: Palette.good)
                    }

                }
                .padding(10)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                SectionTitle("Internet Destinations")

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plugin.summary.destinations.prefix(14)) { destination in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(destinationTitle(destination))
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(destination.count)")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                }
                                Text("\(destination.process) - \(serviceLabel(destination))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(9)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }

                Text(plugin.summary.status)
                    .font(.caption)
                    .foregroundStyle(plugin.summary.health == .ok ? .secondary : Palette.warning)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            if hasBandwidthRows {
                Divider().background(Color.white.opacity(0.08))

                NetworkProcessList(
                    rows: plugin.summary.processes,
                    totalCount: plugin.summary.totalProcessCount,
                    maxRate: plugin.summary.maxCombinedRate
                )
                .padding(16)
                .frame(width: 258)
            }
        }
    }

    private var hasBandwidthRows: Bool {
        !plugin.summary.processes.isEmpty
    }

    private func destinationTitle(_ destination: NetworkDestination) -> String {
        let normalizedAddress = destination.remoteAddress
            .split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? destination.remoteAddress
        let hostname = plugin.summary.resolvedHostnames[normalizedAddress] ?? ""
        return hostname.isEmpty ? "\(serviceLabel(destination)) endpoint" : hostname
    }

    private func serviceLabel(_ destination: NetworkDestination) -> String {
        NetworkCollector.serviceLabel(endpoint: destination.endpoint)
    }
}

struct SpeedTestMetric: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


struct NetworkProcessList: View {
    let rows: [NetworkProcessSnapshot]
    let totalCount: Int
    let maxRate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Bandwidth")
                Spacer()
                Text("\(totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(row.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(rateString(row.combinedRate))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                            HStack {
                                ProgressBar(value: row.combinedRate / maxRate, color: Palette.blue)
                                    .frame(height: 6)
                                Text("D \(rateString(row.downloadRate))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 74, alignment: .trailing)
                                Text("U \(rateString(row.uploadRate))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 74, alignment: .trailing)
                            }
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.055))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
    }
}



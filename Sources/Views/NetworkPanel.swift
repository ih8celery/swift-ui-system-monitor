import AppKit
import Foundation
import SwiftUI

struct NetworkPanel: View {
    @ObservedObject var monitor: UnifiedMonitor

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RateCard(title: "Down", value: rateString(monitor.currentDownloadRate), color: Palette.blue)
                    RateCard(title: "Up", value: rateString(monitor.currentUploadRate), color: Palette.tangerine)
                }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    ChartUnitLabel("B/s - last 90s")
                }

                DualSparkline(
                    first: monitor.downloadHistory,
                    second: monitor.uploadHistory,
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
                        Text(monitor.speedTestStatus)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(monitor.speedTestHealth == .degraded ? Palette.warning : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Button {
                            monitor.runSpeedTest()
                        } label: {
                            if monitor.isSpeedTestRunning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "gauge.with.dots.needle.67percent")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(monitor.isSpeedTestRunning)
                        .help("Run networkQuality speed test")
                    }

                    HStack(spacing: 10) {
                        SpeedTestMetric(label: "Test Down", value: speedTestRateText(monitor.speedTestResult?.downloadMbps), color: Palette.blue)
                        SpeedTestMetric(label: "Test Up", value: speedTestRateText(monitor.speedTestResult?.uploadMbps), color: Palette.tangerine)
                        SpeedTestMetric(label: "Latency", value: speedTestLatencyText(monitor.speedTestResult?.latencyMS), color: Palette.good)
                    }

                }
                .padding(10)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                SectionTitle("Internet Destinations")

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(monitor.destinations.prefix(14)) { destination in
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

                Text(monitor.networkStatus)
                    .font(.caption)
                    .foregroundStyle(monitor.networkHealth == .ok ? .secondary : Palette.warning)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            if hasBandwidthRows {
                Divider().background(Color.white.opacity(0.08))

                NetworkProcessList(
                    rows: monitor.networkProcesses,
                    totalCount: monitor.networkProcessCount,
                    maxRate: monitor.networkMaxCombinedRate
                )
                .padding(16)
                .frame(width: 258)
            }
        }
    }

    private var hasBandwidthRows: Bool {
        !monitor.networkProcesses.isEmpty
    }

    private func destinationTitle(_ destination: NetworkDestination) -> String {
        let normalizedAddress = destination.remoteAddress
            .split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? destination.remoteAddress
        let hostname = monitor.resolvedHostnames[normalizedAddress] ?? ""
        return hostname.isEmpty ? "\(serviceLabel(destination)) endpoint" : hostname
    }

    private func serviceLabel(_ destination: NetworkDestination) -> String {
        UnifiedMonitor.serviceLabel(endpoint: destination.endpoint)
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



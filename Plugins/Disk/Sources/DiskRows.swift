import Foundation
import SwiftUI
import SystemBarKit

enum DiskRowKind: Equatable {
    /// A measured folder with no measured descendant.
    case folder
    /// The part of a measured folder its measured children do not explain.
    case remainder
    /// Every simulator device, as one row.
    case simulatorGroup
    /// One simulator device.
    case simulator
}

/// One line of the right-hand list, or one slice of the left-hand distribution.
struct DiskRow: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let bytes: UInt64
    let measuredAt: Date
    let kind: DiskRowKind
    let simulator: SimulatorInfo?
}

/// A row and how it changed over the chosen window.
struct DiskMover: Identifiable, Equatable {
    enum Change: Equatable {
        case grew(UInt64)
        case shrank(UInt64)
        /// First seen inside the window.
        case new
        /// Went from this many bytes to zero.
        case freed(UInt64)
    }

    var id: String { row.path }
    let row: DiskRow
    let change: Change

    /// What the movers list ranks by.
    var magnitude: UInt64 {
        switch change {
        case .grew(let bytes), .shrank(let bytes), .freed(let bytes): return bytes
        case .new: return row.bytes
        }
    }
}

/// Pure functions from the ledger to what the panel shows. Nothing here reads the disk.
enum DiskRows {
    static let listLimit = 25
    static let distributionLimit = 6

    /// Every latest sample as a row at the deepest measured level: a folder whose measured
    /// children exist appears only as its remainder, and simulator devices fold into one group,
    /// so no byte is shown twice. Library holds Developer, which holds CoreSimulator: showing all
    /// three whole would bill the same space three times.
    static func rows(from ledger: DiskLedger, homeDirectory: String) -> [DiskRow] {
        let latest = ledger.latest
        let devices = latest.filter { $0.simulator != nil }
        let folders = latest.filter { $0.simulator == nil }

        var rows: [DiskRow] = []
        var bytesByPath: [String: UInt64] = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0.bytes) })
        if let group = simulatorGroup(devices) {
            rows.append(group)
            bytesByPath[group.path] = group.bytes
        }
        let measuredPaths = Array(bytesByPath.keys)

        for sample in folders {
            let children = directChildren(of: sample.path, among: measuredPaths)
            if children.isEmpty {
                rows.append(DiskRow(name: displayName(sample.path, homeDirectory: homeDirectory), path: sample.path, bytes: sample.bytes, measuredAt: sample.measuredAt, kind: .folder, simulator: nil))
                continue
            }
            let explained = children.reduce(UInt64(0)) { $0 &+ (bytesByPath[$1] ?? 0) }
            let rest = sample.bytes > explained ? sample.bytes - explained : 0
            rows.append(DiskRow(name: "\(displayName(sample.path, homeDirectory: homeDirectory)) (rest)", path: sample.path, bytes: rest, measuredAt: sample.measuredAt, kind: .remainder, simulator: nil))
        }
        return rows
    }

    /// One row for every simulator device, as old as the oldest device measurement, so the age
    /// shown is never newer than the data behind it.
    private static func simulatorGroup(_ devices: [DiskSample]) -> DiskRow? {
        guard let first = devices.first, let oldest = devices.map(\.measuredAt).min() else { return nil }
        let count = devices.count
        return DiskRow(
            name: "Simulators · \(count) device\(count == 1 ? "" : "s")",
            path: (first.path as NSString).deletingLastPathComponent,
            bytes: devices.reduce(UInt64(0)) { $0 &+ $1.bytes },
            measuredAt: oldest,
            kind: .simulatorGroup,
            simulator: nil
        )
    }

    /// One row per device, biggest first, for the expanded simulator group.
    static func simulatorRows(from ledger: DiskLedger) -> [DiskRow] {
        ledger.latest
            .compactMap { sample -> DiskRow? in
                guard let info = sample.simulator else { return nil }
                return DiskRow(name: "\(info.name) · \(info.runtime)", path: sample.path, bytes: sample.bytes, measuredAt: sample.measuredAt, kind: .simulator, simulator: info)
            }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    /// The measured paths under `parent` with no other measured path between them and it.
    static func directChildren(of parent: String, among paths: [String]) -> [String] {
        let prefix = parent + "/"
        let under = paths.filter { $0.hasPrefix(prefix) }
        return under.filter { child in
            !under.contains { other in other != child && child.hasPrefix(other + "/") }
        }
    }

    static func biggest(_ rows: [DiskRow], limit: Int = listLimit) -> [DiskRow] {
        Array(rows.filter { $0.bytes > 0 }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }.prefix(limit))
    }

    /// Each row against its own newest sample from at or before `window` ago. A row with no such
    /// sample is new when it was first measured inside the window, and silent otherwise: a
    /// folder measured once, before the window, has nothing to be compared with.
    static func movers(rows: [DiskRow], ledger: DiskLedger, window: TimeInterval, now: Date, limit: Int = listLimit) -> [DiskMover] {
        let since = now.addingTimeInterval(-window)
        let history = SampleHistory(ledger)
        let movers = rows.compactMap { row -> DiskMover? in
            guard row.kind != .remainder else { return nil }
            guard let earlier = earlierBytes(of: row, history: history, atOrBefore: since) else {
                return row.measuredAt > since && row.bytes > 0 ? DiskMover(row: row, change: .new) : nil
            }
            if row.bytes == 0, earlier > 0 { return DiskMover(row: row, change: .freed(earlier)) }
            if row.bytes > earlier { return DiskMover(row: row, change: .grew(row.bytes - earlier)) }
            if row.bytes < earlier { return DiskMover(row: row, change: .shrank(earlier - row.bytes)) }
            return nil
        }
        return Array(movers.sorted { $0.magnitude != $1.magnitude ? $0.magnitude > $1.magnitude : $0.row.path < $1.row.path }.prefix(limit))
    }

    /// A folder's earlier size is its own earlier sample; the simulator group's is the sum of
    /// its devices' earlier samples, nil when none of them has one.
    private static func earlierBytes(of row: DiskRow, history: SampleHistory, atOrBefore since: Date) -> UInt64? {
        guard row.kind == .simulatorGroup else {
            return history.sample(of: row.path, atOrBefore: since)?.bytes
        }
        let earlier = history.devicePaths.compactMap { history.sample(of: $0, atOrBefore: since)?.bytes }
        return earlier.isEmpty ? nil : earlier.reduce(0, &+)
    }

    /// The ledger's samples grouped by path, built once per `movers` call so each lookup scans
    /// one path's few samples rather than the whole ledger. It answers exactly as
    /// `DiskLedger.sample(of:atOrBefore:)` and `DiskLedger.latest` do, ties included.
    private struct SampleHistory {
        /// Each path's samples, oldest first. Samples with the same time are ordered latest
        /// appended first, so the last match for any cut-off is the earliest appended of the
        /// newest: the one the ledger's `max(by:)` and `latest` keep.
        private let byPath: [String: [DiskSample]]
        /// The paths whose newest sample is a simulator device.
        let devicePaths: [String]

        init(_ ledger: DiskLedger) {
            let grouped = Dictionary(grouping: ledger.samples.enumerated(), by: { $0.element.path })
            let ordered = grouped.mapValues { entries in
                entries
                    .sorted { $0.element.measuredAt != $1.element.measuredAt ? $0.element.measuredAt < $1.element.measuredAt : $0.offset > $1.offset }
                    .map(\.element)
            }
            byPath = ordered
            devicePaths = ordered.compactMap { path, samples in samples.last?.simulator != nil ? path : nil }.sorted()
        }

        func sample(of path: String, atOrBefore date: Date) -> DiskSample? {
            byPath[path]?.last { $0.measuredAt <= date }
        }
    }

    /// The left column's second bar: the biggest rows, then the rest of what is used, then free,
    /// all slices of the volume's capacity. Labels must be distinct for the legend, so a repeated
    /// name carries its path.
    static func distribution(biggest: [DiskRow], volume: DiskVolume, homeDirectory: String, limit: Int = distributionLimit) -> [BarSegment] {
        let colors = [Palette.cyan, Palette.blue, Palette.purple, Palette.tangerine, Palette.caution, Palette.warning]
        let top = Array(biggest.prefix(limit))
        let shown = top.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let rest = volume.used > shown ? volume.used - shown : 0
        var seen = Set<String>()
        let slices = top.enumerated().map { index, row -> BarSegment in
            let label = seen.insert(row.name).inserted ? row.name : "\(row.name) · \(displayPath(row.path, homeDirectory: homeDirectory))"
            return BarSegment(label: label, value: row.bytes, color: colors[index % colors.count])
        }
        return slices + [
            BarSegment(label: "Everything else", value: rest, color: Color.white.opacity(0.35)),
            BarSegment(label: "Free", value: volume.free, color: Palette.good),
        ]
    }

    static func displayName(_ path: String, homeDirectory: String) -> String {
        path == homeDirectory ? "~" : (path as NSString).lastPathComponent
    }

    static func displayPath(_ path: String, homeDirectory: String) -> String {
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") { return "~" + path.dropFirst(homeDirectory.count) }
        return path
    }
}

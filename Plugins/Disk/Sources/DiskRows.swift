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

        let group = simulatorGroup(devices)
        let plainFolders = folders.filter { $0.path != group?.path }
        var measured: [String: (bytes: UInt64, measuredAt: Date)] = Dictionary(uniqueKeysWithValues: plainFolders.map { ($0.path, ($0.bytes, $0.measuredAt)) })
        var rows: [DiskRow] = []
        if let group {
            rows.append(group)
            measured[group.path] = (group.bytes, group.measuredAt)
        }
        let measuredPaths = Array(measured.keys)

        for sample in plainFolders {
            let children = directChildren(of: sample.path, among: measuredPaths)
            if children.isEmpty {
                rows.append(DiskRow(name: displayName(sample.path, homeDirectory: homeDirectory), path: sample.path, bytes: sample.bytes, measuredAt: sample.measuredAt, kind: .folder, simulator: nil))
                continue
            }
            let explained = children.reduce(UInt64(0)) { $0 &+ (measured[$1]?.bytes ?? 0) }
            let rest = sample.bytes > explained ? sample.bytes - explained : 0
            // As old as the oldest number it is computed from, never flattered by a fresher parent.
            let oldest = children.compactMap { measured[$0]?.measuredAt }.reduce(sample.measuredAt, min)
            rows.append(DiskRow(name: "\(displayName(sample.path, homeDirectory: homeDirectory)) (rest)", path: sample.path, bytes: rest, measuredAt: oldest, kind: .remainder, simulator: nil))
        }
        return rows
    }

    /// One row for every simulator device still present, as old as the oldest device
    /// measurement, so the age shown is never newer than the data behind it. A device measured
    /// at zero bytes has been deleted and is neither counted nor summed.
    private static func simulatorGroup(_ allDevices: [DiskSample]) -> DiskRow? {
        let devices = allDevices.filter { $0.bytes > 0 }
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

    /// One row per present device, biggest first, for the expanded simulator group.
    static func simulatorRows(from ledger: DiskLedger) -> [DiskRow] {
        allSimulatorRows(from: ledger).filter { $0.bytes > 0 }
    }

    /// Every device the ledger knows, deleted ones (measured at zero) included, so movers can
    /// show a deleted device as freed.
    private static func allSimulatorRows(from ledger: DiskLedger) -> [DiskRow] {
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

    /// Each row against its own newest sample from at or before `window` ago. Simulator devices
    /// are compared one by one, deleted ones included, never as the group: a group's earlier
    /// sum can cover a different set of devices. A row with no earlier sample is new only when
    /// its plan had already looked before the window and did not see it; otherwise it is
    /// silent, so a first scan, or a folder a budget cut-off skipped, is never called new.
    static func movers(rows: [DiskRow], ledger: DiskLedger, window: TimeInterval, now: Date, limit: Int = listLimit) -> [DiskMover] {
        let since = now.addingTimeInterval(-window)
        let history = SampleHistory(ledger)
        let compared = rows.flatMap { row in row.kind == .simulatorGroup ? allSimulatorRows(from: ledger) : [row] }
        let movers = compared.compactMap { row -> DiskMover? in
            guard row.kind != .remainder else { return nil }
            guard let earlier = history.sample(of: row.path, atOrBefore: since)?.bytes else {
                let planHadLooked = history.plan(of: row.path).map { history.planHadRun($0, atOrBefore: since) } ?? false
                return planHadLooked && row.bytes > 0 ? DiskMover(row: row, change: .new) : nil
            }
            if row.bytes == 0, earlier > 0 { return DiskMover(row: row, change: .freed(earlier)) }
            if row.bytes > earlier { return DiskMover(row: row, change: .grew(row.bytes - earlier)) }
            if row.bytes < earlier { return DiskMover(row: row, change: .shrank(earlier - row.bytes)) }
            return nil
        }
        return Array(movers.sorted { $0.magnitude != $1.magnitude ? $0.magnitude > $1.magnitude : $0.row.path < $1.row.path }.prefix(limit))
    }

    /// The ledger's samples grouped by path, built once per `movers` call so each lookup scans
    /// one path's few samples rather than the whole ledger. It answers exactly as
    /// `DiskLedger.sample(of:atOrBefore:)` and `DiskLedger.latest` do, ties included.
    private struct SampleHistory {
        /// Each path's samples, oldest first. Samples with the same time are ordered latest
        /// appended first, so the last match for any cut-off is the earliest appended of the
        /// newest: the one the ledger's `max(by:)` and `latest` keep.
        private let byPath: [String: [DiskSample]]
        /// When each plan first appears in the ledger.
        private let earliestRun: [DiskPlanKind: Date]

        init(_ ledger: DiskLedger) {
            let grouped = Dictionary(grouping: ledger.samples.enumerated(), by: { $0.element.path })
            byPath = grouped.mapValues { entries in
                entries
                    .sorted { $0.element.measuredAt != $1.element.measuredAt ? $0.element.measuredAt < $1.element.measuredAt : $0.offset > $1.offset }
                    .map(\.element)
            }
            earliestRun = ledger.samples.reduce(into: [:]) { earliest, sample in
                earliest[sample.plan] = min(earliest[sample.plan] ?? sample.measuredAt, sample.measuredAt)
            }
        }

        func sample(of path: String, atOrBefore date: Date) -> DiskSample? {
            byPath[path]?.last { $0.measuredAt <= date }
        }

        /// The plan of the path's newest sample: the plan that measures it now.
        func plan(of path: String) -> DiskPlanKind? {
            byPath[path]?.last?.plan
        }

        func planHadRun(_ plan: DiskPlanKind, atOrBefore date: Date) -> Bool {
            earliestRun[plan].map { $0 <= date } ?? false
        }
    }

    /// The left column's second bar: the biggest rows, then the rest of what is used, then free,
    /// all slices of the volume's capacity. Labels must be distinct for the legend, so a repeated
    /// name carries its path.
    static func distribution(biggest: [DiskRow], volume: DiskVolume, homeDirectory: String, limit: Int = distributionLimit) -> [BarSegment] {
        let top = Array(biggest.prefix(limit))
        let shown = top.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let rest = volume.used > shown ? volume.used - shown : 0
        var seen: Set<String> = [everythingElseLabel, freeLabel]
        let slices = top.enumerated().map { index, row -> BarSegment in
            let label = seen.insert(row.name).inserted ? row.name : "\(row.name) · \(displayPath(row.path, homeDirectory: homeDirectory))"
            // Colours cycle when `limit` is longer than the list.
            return BarSegment(label: label, value: row.bytes, color: seriesColors[index % seriesColors.count])
        }
        return slices + [
            BarSegment(label: everythingElseLabel, value: rest, color: otherColor),
            BarSegment(label: freeLabel, value: volume.free, color: Palette.good),
        ]
    }

    private static let everythingElseLabel = "Everything else"
    private static let freeLabel = "Free"

    /// Six visibly distinct series colours for the distribution's slices. None is green, which
    /// is Free's colour, and none is a status colour, because a slice is neither good nor bad.
    private static let seriesColors: [Color] = [
        Palette.cyan,
        Palette.blue,
        Palette.purple,
        Palette.tangerine,
        Color(red: 0.96, green: 0.42, blue: 0.68),
        Color(red: 0.80, green: 0.70, blue: 0.52),
    ]

    /// "Everything else": used space no measured row explains.
    private static let otherColor = Color.white.opacity(0.35)

    static func displayName(_ path: String, homeDirectory: String) -> String {
        path == homeDirectory ? "~" : (path as NSString).lastPathComponent
    }

    static func displayPath(_ path: String, homeDirectory: String) -> String {
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") { return "~" + path.dropFirst(homeDirectory.count) }
        return path
    }
}

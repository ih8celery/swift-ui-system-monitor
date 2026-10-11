import Foundation
import SystemBarKit

/// The ledger's file: round trip, a missing file, a broken file moved aside, and the folder
/// created on first save. Every test writes inside a temporary folder it removes.
@MainActor
enum DiskStoreTests {
    static func runAll() {
        testStandardStoreLivesInThePluginsDataFolder()
        testMissingFileIsFresh()
        testSaveCreatesTheFolderAndLoadReadsBackEqual()
        testBrokenFileIsMovedAsideAndReported()
        testWrongVersionIsMovedAside()
        testFractionalDatesRoundTripExactly()
    }

    private static func testStandardStoreLivesInThePluginsDataFolder() {
        let store = DiskLedgerStore.standard(dataDirectory: URL(fileURLWithPath: "/data/disk"))
        expect(store.fileURL.path == "/data/disk/disk-ledger.json", "the ledger is one file in the plugin's own folder, got \(store.fileURL.path)")
    }

    private static func testMissingFileIsFresh() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("none/disk-ledger.json"))
        expect(store.load() == .fresh, "no file means a fresh start, not an error")
    }

    private static func testSaveCreatesTheFolderAndLoadReadsBackEqual() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("disk/disk-ledger.json"))
        let info = SimulatorInfo(udid: "A", name: "iPhone", runtime: "iOS 26.5", lastBootedAt: Date(timeIntervalSince1970: 2_000))
        let ledger = DiskLedger().appending([
            DiskSample(path: "/Users/ada/proj", bytes: 42, measuredAt: Date(timeIntervalSince1970: 1_000), plan: .overview),
            DiskSample(path: "/Users/ada/Library/Developer/CoreSimulator/Devices/A", bytes: 7, measuredAt: Date(timeIntervalSince1970: 1_500), plan: .simulators, simulator: info),
        ])
        do {
            try store.save(ledger)
        } catch {
            expect(false, "save creates the folder and writes: \(error)")
        }
        expect(store.load() == .loaded(ledger), "what was saved loads back equal (dates are whole seconds, which ISO 8601 keeps), got \(store.load())")
    }

    private static func testBrokenFileIsMovedAsideAndReported() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("disk-ledger.json"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: store.fileURL)
        guard case let .movedAside(to, reason) = store.load() else {
            expect(false, "a file that will not parse is moved aside, got \(store.load())")
            return
        }
        expect(to == store.fileURL.path + ".broken", "it is renamed with a .broken suffix, got \(to)")
        expect(!reason.isEmpty, "and the reason is kept for the status line")
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path) && FileManager.default.fileExists(atPath: to), "the broken file is out of the way and still there to look at")
        expect(store.load() == .fresh, "so the next load starts fresh")
    }

    private static func testWrongVersionIsMovedAside() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("disk-ledger.json"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(#"{ "version": 99, "samples": [] }"#.utf8).write(to: store.fileURL)
        guard case let .movedAside(_, reason) = store.load() else {
            expect(false, "a ledger from a version this code does not know is moved aside, got \(store.load())")
            return
        }
        expect(reason.contains("99"), "the reason names the version, got \(reason)")
    }

    private static func testFractionalDatesRoundTripExactly() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("disk-ledger.json"))
        let ledger = DiskLedger().appending([
            DiskSample(path: "/a", bytes: 1, measuredAt: Date(timeIntervalSince1970: 1_000.7), plan: .overview),
            DiskSample(path: "/b", bytes: 2, measuredAt: Date(timeIntervalSince1970: 1_500.2), plan: .overview),
        ])
        do {
            try store.save(ledger)
        } catch {
            expect(false, "save writes: \(error)")
        }
        expect(store.load() == .loaded(ledger), "a ledger built from Date() values equals itself after a save and load, got \(store.load())")
        if case let .loaded(loaded) = store.load() {
            expect(loaded.samples.map { $0.measuredAt.timeIntervalSince1970 } == [1_000, 1_500], "dates are rounded down to the whole second, got \(loaded.samples.map { $0.measuredAt })")
        } else {
            expect(false, "the ledger loads")
        }
    }
}

import Foundation

/// The ledger's one file, in the plugin's data folder. Writes are atomic (Foundation writes a
/// temporary file and renames it into place), so a crash mid-write never leaves half a file.
struct DiskLedgerStore {
    static let fileName = "disk-ledger.json"

    let fileURL: URL

    static func standard(dataDirectory: URL) -> DiskLedgerStore {
        DiskLedgerStore(fileURL: dataDirectory.appendingPathComponent(fileName))
    }

    enum LoadOutcome: Equatable {
        /// No file yet.
        case fresh
        case loaded(DiskLedger)
        /// The file could not be used and was renamed with a `.broken` suffix; `to` is where it
        /// went, `reason` why. The caller starts fresh and says so.
        case movedAside(to: String, reason: String)
    }

    func load() -> LoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return .fresh
        } catch {
            return moveAside(reason: error.localizedDescription)
        }
        let ledger: DiskLedger
        do {
            ledger = try Self.decoder.decode(DiskLedger.self, from: data)
        } catch {
            return moveAside(reason: "not a ledger: \(error.localizedDescription)")
        }
        guard ledger.version == DiskLedger.currentVersion else {
            return moveAside(reason: "version \(ledger.version), but this build reads version \(DiskLedger.currentVersion)")
        }
        return .loaded(ledger)
    }

    private func moveAside(reason: String) -> LoadOutcome {
        let aside = fileURL.appendingPathExtension("broken")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
        } catch {
            return .movedAside(to: aside.path, reason: "\(reason); and it could not be moved aside: \(error.localizedDescription)")
        }
        return .movedAside(to: aside.path, reason: reason)
    }

    /// Creates the plugin's folder on first use, then writes atomically.
    func save(_ ledger: DiskLedger) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(ledger).write(to: fileURL, options: .atomic)
    }

    /// Whole-second ISO 8601 dates and sorted keys, so the file diffs sanely and reads by eye.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

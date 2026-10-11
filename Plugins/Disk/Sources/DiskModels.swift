import Foundation
import SystemBarKit

struct DiskVolume: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let total: UInt64
    /// Plain free space, what `df` calls available. Space macOS could purge is not counted:
    /// it is still on the disk, and the map on this tab is of what is on the disk.
    let free: UInt64
    let isRoot: Bool

    var used: UInt64 {
        total > free ? total - free : 0
    }

    var freeRatio: Double {
        Double(free) / Double(max(total, 1))
    }
}

struct DiskHog: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let size: UInt64
    let hint: String
}

struct DiskSnapshot {
    var volumes: [DiskVolume] = []
    var hogs: [DiskHog] = []
    var localSnapshotCount = 0
    var status = "Waiting for disk sample"
    var health = SampleHealth.degraded
    var hogStatus = "Reclaimable paths not scanned yet"
    var isScanningHogs = false
    var lastUpdated: Date?
    var lastHogScan: Date?

    var boot: DiskVolume? {
        volumes.first(where: \.isRoot)
    }

    var otherVolumes: [DiskVolume] {
        volumes.filter { !$0.isRoot }
    }

    var maxHogSize: UInt64 {
        max(hogs.map(\.size).max() ?? 1, 1)
    }

    /// Candidates may nest (CocoaPods lives inside User Caches), so only paths with no measured
    /// ancestor contribute; counting both would bill the same bytes twice.
    var reclaimableTotal: UInt64 {
        let paths = hogs.map(\.path)
        return hogs
            .filter { hog in !paths.contains { $0 != hog.path && hog.path.hasPrefix("\($0)/") } }
            .reduce(0) { $0 &+ $1.size }
    }
}

/// A path worth measuring because it grows without being asked and can be deleted without losing work.
struct DiskHogCandidate {
    let name: String
    /// Absolute when it starts with "/", otherwise resolved against the home directory.
    let path: String
    let hint: String

    static let all: [DiskHogCandidate] = [
        DiskHogCandidate(name: "Xcode DerivedData", path: "Library/Developer/Xcode/DerivedData", hint: "Build intermediates. Safe to delete; next build is slower."),
        DiskHogCandidate(name: "Xcode Archives", path: "Library/Developer/Xcode/Archives", hint: "Shipped build archives. Keep only what you may resubmit."),
        DiskHogCandidate(name: "iOS Simulators", path: "Library/Developer/CoreSimulator", hint: "Simulator runtimes and devices. Prune with xcrun simctl delete unavailable."),
        DiskHogCandidate(name: "Xcode Device Support", path: "Library/Developer/Xcode/iOS DeviceSupport", hint: "Per-iOS-version symbols. Old versions are dead weight."),
        DiskHogCandidate(name: "Docker", path: "Library/Containers/com.docker.docker", hint: "Docker.raw disk image. Reclaim with docker system prune."),
        DiskHogCandidate(name: "User Caches", path: "Library/Caches", hint: "App caches. Safe to delete; apps refill what they need."),
        DiskHogCandidate(name: "Downloads", path: "Downloads", hint: "Usually the cheapest space to reclaim."),
        DiskHogCandidate(name: "Trash", path: ".Trash", hint: "Not free until emptied."),
        DiskHogCandidate(name: "npm Cache", path: ".npm", hint: "Package cache. Reclaim with npm cache clean --force."),
        DiskHogCandidate(name: "Cargo", path: ".cargo", hint: "Rust registry and build cache."),
        DiskHogCandidate(name: "Gradle", path: ".gradle", hint: "Android/JVM build cache."),
        DiskHogCandidate(name: "Maven", path: ".m2", hint: "JVM dependency cache."),
        DiskHogCandidate(name: "Go Modules", path: "go/pkg", hint: "Module cache. Reclaim with go clean -modcache."),
        DiskHogCandidate(name: "Expo", path: ".expo", hint: "Expo build and asset cache."),
        DiskHogCandidate(name: "CocoaPods", path: "Library/Caches/CocoaPods", hint: "Pod spec and source cache."),
        DiskHogCandidate(name: "System Caches", path: "/Library/Caches", hint: "Shared caches. Safe to delete; may need admin rights."),
    ]

    func resolvedPath(homeDirectory: String) -> String {
        path.hasPrefix("/") ? path : "\(homeDirectory)/\(path)"
    }
}

/// How often the Disk tab samples, and how long its du scan may run.
enum DiskSampling {
    static let refreshInterval: TimeInterval = 30
    /// `du` walks real directory trees, so it runs far less often than the capacity read it ships with.
    static let hogRefreshInterval: TimeInterval = 600
    /// Per-tree ceiling. Generous, because a cold DerivedData or CoreSimulator walk is slow,
    /// but bounded so one pathological tree cannot hold the whole scan open.
    static let hogPathTimeout: TimeInterval = 45
    /// Whole-scan ceiling, kept well under the refresh interval so scans never overlap.
    static let hogScanBudget: TimeInterval = 240
}

/// What one 30-second volume read found.
struct DiskVolumeReading {
    let volumes: [DiskVolume]
    let localSnapshotCount: Int
    let sampledAt: Date

    var status: String { volumes.isEmpty ? "No readable volumes found" : "Disk sample OK" }
    var health: SampleHealth { SampleHealth(isOK: !volumes.isEmpty) }
}

/// What the hog scan reports as it goes, so the list fills in tree by tree.
enum DiskHogUpdate {
    case started
    case progress([DiskHog])
    case finished(hogs: [DiskHog], status: String, at: Date)
}

extension DiskSnapshot {
    /// A copy with a volume reading applied; the hog fields are left alone.
    func applying(_ reading: DiskVolumeReading) -> DiskSnapshot {
        var next = self
        next.volumes = reading.volumes
        next.localSnapshotCount = reading.localSnapshotCount
        next.status = reading.status
        next.health = reading.health
        next.lastUpdated = reading.sampledAt
        return next
    }

    /// A copy with one hog-scan update applied; the volume fields are left alone.
    func applying(_ update: DiskHogUpdate) -> DiskSnapshot {
        var next = self
        switch update {
        case .started:
            next.isScanningHogs = true
            next.hogStatus = "Measuring reclaimable paths"
        case .progress(let hogs):
            next.hogs = hogs
        case let .finished(hogs, status, at):
            next.hogs = hogs
            next.hogStatus = status
            next.isScanningHogs = false
            next.lastHogScan = at
        }
        return next
    }
}

import Foundation
import SystemBarKit

/// The two Foundation calls that load a bundle, behind a protocol so the loader's outcomes can
/// be tested without a real dylib.
protocol BundleLoading {
    /// Loads the bundle at `url` and returns its principal class, `nil` when Info.plist names
    /// none, or throws when the bundle is not a bundle or its code will not load.
    func principalClass(at url: URL) throws -> AnyClass?
}

struct FoundationBundleLoader: BundleLoading {
    func principalClass(at url: URL) throws -> AnyClass? {
        guard let bundle = Bundle(url: url) else {
            throw TabLoadError(description: "\(url.lastPathComponent) is not a bundle")
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            throw TabLoadError(description: "\(url.lastPathComponent) would not load: \(error.localizedDescription)")
        }
        return bundle.principalClass
    }
}

/// Resolves an entry to the class inside a `.bundle`: a name inside the app's PlugIns folder, or
/// a path anywhere. Each step that can fail says which one did.
struct BundleTabSource: TabSource {
    let builtInPlugInsURL: URL?
    let homeDirectory: String
    let loader: BundleLoading

    static func standard() -> BundleTabSource {
        BundleTabSource(builtInPlugInsURL: Bundle.main.builtInPlugInsURL, homeDirectory: NSHomeDirectory(), loader: FoundationBundleLoader())
    }

    /// True when a bundle by this name sits in the app's PlugIns folder.
    func hasBundle(named name: String) -> Bool {
        guard let url = try? PluginPath.resolve(PluginEntry(name: name, path: nil, isEnabled: true), builtInPlugInsURL: builtInPlugInsURL, homeDirectory: homeDirectory) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type {
        let url = try PluginPath.resolve(entry, builtInPlugInsURL: builtInPlugInsURL, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TabLoadError(description: "nothing at \(url.path)")
        }
        guard let cls = try loader.principalClass(at: url) else {
            throw TabLoadError(description: "\(url.lastPathComponent) names no NSPrincipalClass in its Info.plist, or that class is not in its code")
        }
        guard let type = cls as? TabPlugin.Type else {
            throw TabLoadError(description: "\(NSStringFromClass(cls)) in \(url.lastPathComponent) does not adopt TabPlugin")
        }
        return type
    }
}

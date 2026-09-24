import Foundation
import SystemBarKit

/// The Foundation calls that load a bundle and read its principal class, behind a protocol so
/// the loader's outcomes can be tested without a real dylib.
protocol BundleLoading {
    /// Loads the bundle at `url` and returns its principal class, or throws when the bundle is
    /// not a bundle, its code will not load, its Info.plist names no `NSPrincipalClass`, or that
    /// class is not in its code.
    func principalClass(at url: URL) throws -> AnyClass
}

struct FoundationBundleLoader: BundleLoading {
    func principalClass(at url: URL) throws -> AnyClass {
        guard let bundle = Bundle(url: url) else {
            throw TabLoadError(description: "\(url.lastPathComponent) is not a bundle")
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            // The localized description is the generic "couldn't be loaded" message; the actual
            // dyld reason (bad architecture, a missing symbol) lives in the NSError's debug
            // description, when Foundation supplies one.
            let nsError = error as NSError
            var reason = "\(url.lastPathComponent) would not load: \(error.localizedDescription)"
            if let debug = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
                let trimmed = debug.range(of: ", tried:").map { String(debug[..<$0.lowerBound]) } ?? debug
                reason += " (\(trimmed))"
            }
            throw TabLoadError(description: reason)
        }
        guard let name = bundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String, !name.isEmpty else {
            throw TabLoadError(description: "\(url.lastPathComponent)'s Info.plist has no NSPrincipalClass")
        }
        // Bundle.classNamed looks the name up in the ObjC runtime, not in this bundle's own
        // image: two bundles exporting the same @objc class name collide there and the first
        // loaded wins, so a plugin's class name should be unique to it.
        guard let cls = bundle.classNamed(name) else {
            throw TabLoadError(description: "\(url.lastPathComponent) names the class \"\(name)\" in NSPrincipalClass, but its code has no class by that name")
        }
        return cls
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
        guard let url = try? PluginPath.resolveName(name, builtInPlugInsURL: builtInPlugInsURL) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type {
        let url = try PluginPath.resolve(entry, builtInPlugInsURL: builtInPlugInsURL, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TabLoadError(description: "nothing at \(url.path)")
        }
        let cls: AnyClass = try loader.principalClass(at: url)
        guard let type = cls as? TabPlugin.Type else {
            throw TabLoadError(description: "\(NSStringFromClass(cls)) in \(url.lastPathComponent) does not adopt TabPlugin")
        }
        return type
    }
}

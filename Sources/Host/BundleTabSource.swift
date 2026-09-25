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
    /// Two bundle URLs name the same bundle when they resolve to the same real path.
    /// `standardizedFileURL` alone does not follow symlinks, but `Bundle(for:)` always reports a
    /// class's bundle by its real, resolved path — so a plugin reached through a symlinked copy
    /// of its own bundle must be resolved the same way before the two are compared, or it reads
    /// as a clash with itself.
    static func isSameBundle(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL
    }

    func principalClass(at url: URL) throws -> AnyClass {
        guard let bundle = Bundle(url: url) else {
            throw TabLoadError(description: "\(url.lastPathComponent) is not a bundle")
        }
        // loadAndReturnError() overwrites NSPrincipalClass in the bundle's info dictionary with
        // whatever class Foundation falls back to, so the real value has to be read before that
        // call, not after it. A bundle with no principal class is refused here and never loaded.
        guard let name = bundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String, !name.isEmpty else {
            throw TabLoadError(description: "\(url.lastPathComponent)'s Info.plist has no NSPrincipalClass")
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
        // Bundle.classNamed only finds a class in this bundle's own code: when two bundles export
        // the same @objc name, the ObjC runtime keeps whichever loaded first, so a later bundle's
        // own class becomes invisible to classNamed under that name. NSClassFromString reaches
        // the runtime's global name table instead, so a nil from classNamed here is checked
        // against it before giving up — that turns the collision into an "already defined by"
        // error naming the other bundle, rather than the misleading "its code has no class by
        // that name". The same collision can also show up as classNamed succeeding with a class
        // that belongs to a different bundle (one loaded under this name before this one), so
        // that is checked too. A plugin's @objc name must be unique to it.
        func alreadyDefinedError(by other: AnyClass) -> TabLoadError {
            TabLoadError(description: "\(url.lastPathComponent) names the class \"\(name)\", but that class is already defined by \(Bundle(for: other).bundlePath); give this plugin a unique @objc name")
        }
        if let cls = bundle.classNamed(name) {
            guard Self.isSameBundle(Bundle(for: cls).bundleURL, url) else {
                throw alreadyDefinedError(by: cls)
            }
            return cls
        }
        if let existing = NSClassFromString(name) {
            throw alreadyDefinedError(by: existing)
        }
        throw TabLoadError(description: "\(url.lastPathComponent) names the class \"\(name)\" in NSPrincipalClass, but its code has no class by that name")
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

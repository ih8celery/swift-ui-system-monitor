import Foundation

/// The kinds of expensive work worth accounting for per project. Anything that matches none of
/// these is ordinary machine activity and stays out of the ledger entirely.
///
/// Ported from `categoryForProcess` in ShotStep's `scripts/machine-capacity.js`, deliberately
/// pattern-for-pattern: the two implementations grade the same machine, so they must never
/// disagree about what a process is. Changing a pattern here means changing it there.
enum WorkCategory: String, CaseIterable {
    case nativeBuild
    case simulator
    case testRunner
    case bundler
    case automation

    /// Plain english, because "Xcode build ×6" explains your fans and "swift-frontend ×6" doesn't.
    var label: String {
        switch self {
        case .nativeBuild: return "Xcode build"
        case .simulator: return "Simulator"
        case .testRunner: return "Test runner"
        case .bundler: return "Metro or Expo bundler"
        case .automation: return "Maestro automation"
        }
    }

    /// First match wins, in the same order the capacity script tries them. Build, test, bundler
    /// and automation are recognised from the full command line; the simulator is recognised from
    /// the executable path, because its processes carry no telling arguments.
    static func classify(path: String, args: String) -> WorkCategory? {
        let command = args.lowercased()
        let executable = path.lowercased()

        if matches(nativeBuildPattern, command) { return .nativeBuild }
        if matches(simulatorPattern, executable) { return .simulator }
        if matches(testPattern, command) { return .testRunner }
        if matches(bundlerPattern, command) { return .bundler }
        if matches(automationPattern, command) { return .automation }
        return nil
    }

    /// The trailing `(?:\s|$)` is what keeps `clangd` — a language server, not a compile job — from
    /// being counted as build work.
    private static let nativeBuildPattern = compile(
        #"(?:^|\s|/)(?:xcodebuild|xcbuild|swift-frontend|clang|ld|metal|codesign)(?:\s|$)"#
    )
    private static let simulatorPattern = compile(
        #"(?:coresimulator|/simulator\.app/|/simctl$|/xctest$|/xctrace$)"#
    )
    private static let testPattern = compile(#"\b(?:jest|vitest|mocha)\b"#)
    private static let bundlerPattern = compile(#"\b(?:metro|expo\s+(?:start|run)|react-native)\b"#)
    private static let automationPattern = compile(#"\bmaestro\b"#)

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ expression: NSRegularExpression?, _ subject: String) -> Bool {
        guard let expression else { return false }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        return expression.firstMatch(in: subject, range: range) != nil
    }
}

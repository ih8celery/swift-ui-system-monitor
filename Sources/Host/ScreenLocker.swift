import Darwin
import Foundation
import SystemBarKit

/// The header's power button locks the Mac, the same as Control-Command-Q. macOS has no public
/// call for that, so this uses the one the Lock Screen menu item itself uses,
/// `SACLockScreenImmediate` in the private login framework, looked up at run time so a macOS
/// that drops it costs a fallback rather than a crash. The fallback puts the display to sleep,
/// which locks only when "Require password after the screen saver begins or display is turned
/// off" is set to Immediately.
enum ScreenLocker {
    typealias Runner = (_ path: String, _ arguments: [String], _ environment: [String: String]?, _ timeout: TimeInterval) -> CommandOutput

    private static let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    private static let lockSymbol = "SACLockScreenImmediate"
    private static let pmsetPath = "/usr/bin/pmset"
    private static let pmsetTimeout: TimeInterval = 5

    static func lock(
        lockNow: () -> Bool = lockWithLoginFramework,
        runner: Runner = ProcessRunner.run,
        log: (String) -> Void
    ) {
        if lockNow() {
            return
        }
        log("lock: \(lockSymbol) is unavailable; putting the display to sleep instead, which locks only if a password is required immediately after sleep")
        let sleep = runner(pmsetPath, ["displaysleepnow"], nil, pmsetTimeout)
        if sleep.status != 0 || sleep.didTimeout {
            log("lock: pmset displaysleepnow failed (status \(sleep.status), timed out \(sleep.didTimeout)): \(sleep.error)")
        }
    }

    /// True when the login framework's lock call was found and reported success.
    static func lockWithLoginFramework() -> Bool {
        guard let handle = dlopen(loginFrameworkPath, RTLD_LAZY) else {
            return false
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, lockSymbol) else {
            return false
        }
        typealias LockFunction = @convention(c) () -> Int32
        let lockScreen = unsafeBitCast(symbol, to: LockFunction.self)
        return lockScreen() == 0
    }
}

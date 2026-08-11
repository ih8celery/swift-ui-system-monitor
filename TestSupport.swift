import Foundation

/// Shared by every test file compiled into the in-process test binary. Failing loudly and
/// exiting on the first failure keeps `./test.sh` output to the one thing that broke.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

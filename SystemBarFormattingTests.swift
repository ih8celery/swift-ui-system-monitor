import Foundation
import SystemBarKit

/// Tests for the SDK's text formatters.
struct SystemBarFormattingTests {
    static func runAll() {
        testOlderFormattersAreUnchanged()
    }

    private static func testOlderFormattersAreUnchanged() {
        expect(byteString(1_500_000_000) == "1.40 GB", "byteString should stay 1024-based with two decimals below 10")
        expect(byteString(512) == "512 B", "byteString should read whole bytes below a kilobyte")
        expect(byteString(15 * 1024 * 1024) == "15.0 MB", "byteString should keep one decimal above 10")
        expect(rateString(2.5 * 1024 * 1024) == "2.5 MB/s", "rateString should stay 1024-based")
        expect(rateString(-1) == "0 B/s", "rateString should read a negative rate as 0 B/s")
    }
}

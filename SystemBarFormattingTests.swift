import Foundation
import SystemBarKit

/// Tests for the SDK's text formatters: the Apple-convention byte and rate strings (files and
/// network at 1000, memory at 1024), and the older 1024-based ones kept for existing bundles.
struct SystemBarFormattingTests {
    static func runAll() {
        testFileBytesCountInThousands()
        testMemoryBytesCountInKibibytes()
        testFileRatesCountInThousands()
        testOlderFormattersAreUnchanged()
    }

    private static func testFileBytesCountInThousands() {
        expect(fileByteString(1_500_000_000) == "1.5 GB", "1.5 billion bytes should read 1.5 GB, as Finder shows it")
        expect(fileByteString(0) == "0 B", "zero should read 0 B")
        expect(fileByteString(999) == "999 B", "below a kilobyte should read whole bytes")
        expect(fileByteString(1_000) == "1.0 KB", "a file kilobyte is 1000 bytes")
        expect(fileByteString(245_107_000_000) == "245.1 GB", "large sizes keep one decimal")
        expect(fileByteString(2_000_000_000_000_000) == "2000.0 TB", "terabytes are the largest unit")
    }

    private static func testMemoryBytesCountInKibibytes() {
        expect(memoryByteString(1_500_000_000) == "1.4 GB", "1.5 billion bytes of memory should read 1.4 GB, as Activity Monitor shows it")
        expect(memoryByteString(1_000) == "1000 B", "below 1024 bytes should read whole bytes")
        expect(memoryByteString(1_024) == "1.0 KB", "a memory kilobyte is 1024 bytes")
        expect(memoryByteString(17_179_869_184) == "16.0 GB", "16 GiB of RAM should read 16.0 GB")
    }

    private static func testFileRatesCountInThousands() {
        expect(fileRateString(2_500_000) == "2.5 MB/s", "2.5 million bytes a second should read 2.5 MB/s")
        expect(fileRateString(999) == "999 B/s", "below a kilobyte should read whole bytes a second")
        expect(fileRateString(12_000) == "12 KB/s", "ten of a unit and above should read whole numbers")
        expect(fileRateString(-5) == "0 B/s", "a negative rate should read 0 B/s")
        expect(fileRateString(3_000_000_000_000) == "3000 GB/s", "gigabytes a second are the largest unit")
    }

    private static func testOlderFormattersAreUnchanged() {
        expect(byteString(1_500_000_000) == "1.40 GB", "byteString should stay 1024-based with two decimals below 10")
        expect(byteString(512) == "512 B", "byteString should read whole bytes below a kilobyte")
        expect(byteString(15 * 1024 * 1024) == "15.0 MB", "byteString should keep one decimal above 10")
        expect(rateString(2.5 * 1024 * 1024) == "2.5 MB/s", "rateString should stay 1024-based")
        expect(rateString(-1) == "0 B/s", "rateString should read a negative rate as 0 B/s")
    }
}

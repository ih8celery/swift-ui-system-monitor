import Foundation
import SystemBarKit

/// "used / total" for the Swap pill. Both sides always show, so an empty swap reads "0 B / 0 B".
func swapStatText(used: UInt64, total: UInt64) -> String {
    "\(byteString(used)) / \(byteString(total))"
}

/// The headline's tooltip: what makes up "used", the way Activity Monitor counts it, and the
/// file cache that is deliberately left out. Wired and compressed memory belong to no process in
/// the list, which is why the list never adds up to this figure.
func usedBreakdownText(memory: MemorySnapshot) -> String {
    "\(byteString(memory.used)) used, as Activity Monitor counts it: "
        + "\(byteString(memory.appMemory)) app memory + \(byteString(memory.wired)) wired + \(byteString(memory.compressed)) compressed. "
        + "Wired and compressed memory belong to no process in the list. "
        + "\(byteString(memory.cachedFiles)) of cached files is not counted as used."
}

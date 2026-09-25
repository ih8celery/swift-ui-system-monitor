import Foundation
import SystemBarKit

/// "used / total" for the Swap pill. Both sides always show, so an empty swap reads "0 B / 0 B".
func swapStatText(used: UInt64, total: UInt64) -> String {
    "\(byteString(used)) / \(byteString(total))"
}

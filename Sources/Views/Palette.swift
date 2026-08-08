import SwiftUI

/// Single source of truth for the app's color literals, so a shade only needs to change in
/// one place instead of being hunted down across every view that happens to reuse it.
enum Palette {
    static let background = Color(red: 0.08, green: 0.09, blue: 0.10)
    static let foreground = Color(red: 0.93, green: 0.95, blue: 0.96)

    // Status ramp shared by thermal state, memory pressure, and disk headroom.
    static let good = Color(red: 0.22, green: 0.86, blue: 0.49)
    static let caution = Color(red: 0.96, green: 0.78, blue: 0.28)
    static let warning = Color(red: 0.98, green: 0.63, blue: 0.25)
    static let critical = Color(red: 0.98, green: 0.31, blue: 0.27)

    static let blue = Color(red: 0.30, green: 0.58, blue: 1.0)
    static let tangerine = Color(red: 1.0, green: 0.58, blue: 0.20)
    static let purple = Color(red: 0.72, green: 0.44, blue: 0.95)
    static let cyan = Color(red: 0.36, green: 0.80, blue: 0.86)
}

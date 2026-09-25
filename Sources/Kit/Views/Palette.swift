import SwiftUI

/// Single source of truth for the app's color literals, so a shade only needs to change in
/// one place instead of being hunted down across every view that happens to reuse it.
public enum Palette {
    /// The window's near-black background, behind every tab.
    public static let background = Color(red: 0.08, green: 0.09, blue: 0.10)
    /// The window's default text colour, a near-white.
    public static let foreground = Color(red: 0.93, green: 0.95, blue: 0.96)

    // Status ramp shared by thermal state, memory pressure, and disk headroom, from best to worst.

    /// Green: healthy, plenty of room, nothing to do. Also free memory and free disk space.
    public static let good = Color(red: 0.22, green: 0.86, blue: 0.49)
    /// Yellow: worth a glance, e.g. memory pressure past half or a fair thermal state.
    public static let caution = Color(red: 0.96, green: 0.78, blue: 0.28)
    /// Orange: needs attention, and the colour of a degraded sample's status line.
    public static let warning = Color(red: 0.98, green: 0.63, blue: 0.25)
    /// Red: act now, e.g. a critical thermal state, little memory or disk left, a config error.
    public static let critical = Color(red: 0.98, green: 0.31, blue: 0.27)

    // Series colours, for data with no good-or-bad reading.

    /// Blue: download traffic, active memory, used disk space; the Network tab's accent.
    public static let blue = Color(red: 0.30, green: 0.58, blue: 1.0)
    /// Tangerine orange: upload traffic, paired with `blue` for download.
    public static let tangerine = Color(red: 1.0, green: 0.58, blue: 0.20)
    /// Purple: compressed memory and developer work; the Dev tab's accent.
    public static let purple = Color(red: 0.72, green: 0.44, blue: 0.95)
    /// Cyan: disk space bars; the Disk tab's accent.
    public static let cyan = Color(red: 0.36, green: 0.80, blue: 0.86)
}

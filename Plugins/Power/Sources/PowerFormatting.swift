import Foundation

/// The battery pill's text. Only the Power panel shows it, so it lives here rather than in the
/// Kit, whose public surface every plugin is built against.
func batteryStatLabel(percent: Int, isCharging: Bool?) -> String {
    isCharging == true ? "\(percent)% Charging" : "\(percent)%"
}

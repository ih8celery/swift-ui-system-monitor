import Foundation

/// How hard the machine is being pushed right now.
enum MachineStress {
    case low
    case moderate
    case high
}

/// How much room is left for new work — the one thing a reader acts on.
enum AvailableCapacity {
    case high
    case moderate
    case low

    var label: String {
        switch self {
        case .high: return "HIGH"
        case .moderate: return "MODERATE"
        case .low: return "LOW"
        }
    }
}

/// Whole-machine signals only. Nothing here depends on per-project attribution succeeding, which is
/// why the headline stays trustworthy even when every row below it reads "not measurable".
struct CapacityInputs {
    let cpuBusyPercent: Double?
    let heatHeavyCount: Int
    let thermalState: ProcessInfo.ThermalState
    let hasThermalWarning: Bool
    let hasPerformanceWarning: Bool
    /// Always nil today: no trustworthy no-privilege temperature source exists on this Mac, a gap
    /// ShotStep's zp2s D4 already recorded. The ceiling rule is kept so parity is provable the day
    /// a trustworthy reading is approved.
    let cpuTemperatureCelsius: Double?
}

struct CapacityAssessment {
    let stress: MachineStress
    let availableCapacity: AvailableCapacity
}

/// Ported from `evaluateCapacity` in ShotStep's `scripts/machine-capacity.js`. The bands are the
/// contract between the two: a machine graded MODERATE here must grade moderate there.
enum CapacityGrade {
    /// CPU pressure bands: below working is quiet, working through busy is mid, busy and up is hot.
    static let workingCPUBand: Double = 30
    static let busyCPUBand: Double = 55
    static let saturatedCPUBand: Double = 80
    /// A safety ceiling, not a calibrated fan-on prediction.
    static let temperatureCeiling: Double = 90

    static func assess(_ inputs: CapacityInputs) -> CapacityAssessment {
        // An unavailable reading must not invent stress, so a missing signal counts as quiet.
        let cpuBusy = inputs.cpuBusyPercent ?? 0
        let temperature = inputs.cpuTemperatureCelsius ?? 0
        let heavy = inputs.heatHeavyCount
        let warned = inputs.hasThermalWarning || inputs.hasPerformanceWarning
        let seriousThermalState = inputs.thermalState == .serious || inputs.thermalState == .critical

        let isHigh = warned
            || seriousThermalState
            || temperature >= temperatureCeiling
            || cpuBusy >= saturatedCPUBand
            || (heavy >= 2 && cpuBusy >= busyCPUBand)
        if isHigh {
            return CapacityAssessment(stress: .high, availableCapacity: .low)
        }

        let isModerate = inputs.thermalState == .fair
            || cpuBusy >= busyCPUBand
            || heavy >= 2
            || (heavy >= 1 && cpuBusy >= workingCPUBand)
        if isModerate {
            return CapacityAssessment(stress: .moderate, availableCapacity: .moderate)
        }

        return CapacityAssessment(stress: .low, availableCapacity: .high)
    }
}

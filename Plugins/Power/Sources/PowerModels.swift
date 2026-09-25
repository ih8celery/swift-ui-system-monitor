import Foundation
import SystemBarKit

struct PowerContributor: Identifiable {
    var id: String { name }
    let name: String
    let evidence: String
}

struct PowerSnapshot {
    var powerSource = "Unknown"
    var thermalState = "Unknown"
    var batteryPercent: Int?
    var isCharging: Bool?
    var sleepAssertions: [String] = []
    var contributors: [PowerContributor] = []
    var status = "Waiting for power sample"
    var health = SampleHealth.degraded
    var lastUpdated: Date?
}

import Foundation
import SystemBarKit

/// What the Dev tab shows: how much room the machine has left, and which projects are using it.
struct CapacitySnapshot {
    /// Nil until the first sample completes. The panel says it is measuring rather than showing a
    /// grade nobody has measured yet.
    var assessment: CapacityAssessment?
    var rows: [ProjectWorkRow] = []
    var ports: [DeveloperPort] = []
    var cpuBusyPercent: Double?
    var thermalState = "Unknown"
    var status = "Waiting for capacity sample"
    var health = SampleHealth.degraded
    var lastUpdated: Date?

    var projectCount: Int {
        rows.filter { $0.project != nil }.count
    }

    var projectRows: [ProjectWorkRow] {
        rows.filter { $0.project != nil }
    }

    var unattributedRow: ProjectWorkRow? {
        rows.first { $0.project == nil }
    }

    /// Ports whose process was traced to a project, grouped under that project's name.
    var portsByProject: [(project: String, ports: [DeveloperPort])] {
        let named = ports.compactMap { port in port.projectName.map { ($0, port) } }
        let grouped = Dictionary(grouping: named, by: \.0)
        return grouped
            .map { (project: $0.key, ports: $0.value.map(\.1)) }
            .sorted { $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }
    }

    var unattributedPorts: [DeveloperPort] {
        ports.filter { $0.projectName == nil }
    }
}

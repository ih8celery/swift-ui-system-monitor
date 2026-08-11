import Foundation

/// Tests for the per-project capacity ledger: what kind of work a process is, whose project it
/// belongs to, what its load actually measures, and how the machine is graded overall.
struct SystemBarCapacityTests {
    static func runAll() {
        testWorkCategoryClassification()
        testWorkCategoryLabelsMatchTheCapacityScript()
        testRepositoryWalkUpFindsTheEnclosingRepo()
        testRepositoryWalkUpStopsBeforeHome()
        testRepositoryWalkUpRespectsTheDepthCap()
        testProjectAttributionFromArguments()
        testProjectAttributionCachesDirectoryLookups()
        testProjectRowsMeasureRealDeltas()
        testProjectRowsExcludeUnmeasurablePIDs()
        testProjectRowsReportUnavailableRatherThanZero()
        testProjectRowsOrderHeaviestFirstWithUnattributedLast()
        testCapacityGradeBands()
    }

    // MARK: - Work classification

    /// Ported from machine-capacity.js categoryForProcess. These fixtures are the contract
    /// between the two implementations; if one changes, both must.
    private static func testWorkCategoryClassification() {
        expect(
            WorkCategory.classify(
                path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                args: "swift-frontend -frontend -c /Users/tester/code/app/Sources/Thing.swift"
            ) == .nativeBuild,
            "a swift-frontend compile job should classify as native build work"
        )
        expect(
            WorkCategory.classify(path: "/usr/bin/ld", args: "/usr/bin/ld -o /tmp/App") == .nativeBuild,
            "the linker should classify as native build work when reached by path"
        )
        expect(
            WorkCategory.classify(
                path: "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim",
                args: "launchd_sim"
            ) == .simulator,
            "a CoreSimulator process should classify as simulator work from its executable path"
        )
        expect(
            WorkCategory.classify(
                path: "/usr/local/bin/node",
                args: "node /Users/tester/code/app/node_modules/.bin/jest --runInBand"
            ) == .testRunner,
            "a jest run should classify as test runner work"
        )
        expect(
            WorkCategory.classify(
                path: "/usr/local/bin/node",
                args: "node /Users/tester/code/app/node_modules/.bin/metro serve"
            ) == .bundler,
            "metro should classify as bundler work"
        )
        expect(
            WorkCategory.classify(path: "/usr/local/bin/npx", args: "npx expo start --dev-client") == .bundler,
            "expo start should classify as bundler work"
        )
        expect(
            WorkCategory.classify(
                path: "/usr/bin/java",
                args: "java -jar /Users/tester/.maestro/lib/maestro.jar test flow.yaml"
            ) == .automation,
            "a maestro run should classify as automation work"
        )
        expect(
            WorkCategory.classify(path: "/bin/zsh", args: "-zsh") == nil,
            "an ordinary shell is not expensive work and must stay out of the ledger"
        )
        expect(
            WorkCategory.classify(path: "/usr/bin/clangd", args: "clangd --background-index") == nil,
            "clangd is a language server, not a compile job, and the ported pattern must not widen"
        )
    }

    private static func testWorkCategoryLabelsMatchTheCapacityScript() {
        expect(WorkCategory.nativeBuild.label == "Xcode build", "native build label should read as plain english")
        expect(WorkCategory.simulator.label == "Simulator", "simulator label should read as plain english")
        expect(WorkCategory.testRunner.label == "Test runner", "test label should read as plain english")
        expect(WorkCategory.bundler.label == "Metro or Expo bundler", "bundler label should name both bundlers it detects")
        expect(WorkCategory.automation.label == "Maestro automation", "automation label should name the tool it detects")
    }

    // MARK: - Project attribution

    private static func resolver(
        home: String = "/Users/tester",
        repositories: Set<String>,
        probeCount: UnsafeMutablePointer<Int>? = nil
    ) -> ProjectResolver {
        ProjectResolver(homeDirectory: home) { directory in
            probeCount?.pointee += 1
            return repositories.contains(directory)
        }
    }

    private static func testRepositoryWalkUpFindsTheEnclosingRepo() {
        let found = resolver(repositories: ["/Users/tester/code/app"])
            .repositoryRoot(forPath: "/Users/tester/code/app/node_modules/.bin/metro")
        expect(found == "/Users/tester/code/app", "the walk should climb past nested directories to the enclosing repo")
    }

    /// A dotfiles repository at the home directory would otherwise swallow every process on the
    /// machine, so home is a wall the walk never tests and never crosses.
    private static func testRepositoryWalkUpStopsBeforeHome() {
        let found = resolver(repositories: ["/Users/tester", "/Users"])
            .repositoryRoot(forPath: "/Users/tester/notes.txt")
        expect(found == nil, "a repo at or above the home directory must never become a project")
    }

    private static func testRepositoryWalkUpRespectsTheDepthCap() {
        let deep = "/Users/tester/a/" + Array(repeating: "d", count: 40).joined(separator: "/")
        let found = resolver(repositories: ["/Users/tester/a"]).repositoryRoot(forPath: deep)
        expect(found == nil, "a path deeper than the cap should give up rather than walk unbounded")
    }

    private static func testProjectAttributionFromArguments() {
        let subject = resolver(repositories: ["/Users/tester/code/app"])

        let fromPlainToken = subject.project(
            forArgs: "node /Users/tester/code/app/node_modules/.bin/metro serve"
        )
        expect(fromPlainToken?.rootPath == "/Users/tester/code/app", "an absolute path in args should attribute the process")
        expect(fromPlainToken?.displayName == "app", "the display name should be the repository folder name")

        let fromFlagToken = subject.project(forArgs: "xcodebuild --cwd=/Users/tester/code/app/ios build")
        expect(fromFlagToken?.rootPath == "/Users/tester/code/app", "a path attached to a flag with = should still attribute")

        expect(subject.project(forArgs: "-zsh") == nil, "args with no absolute path cannot attribute and must return nothing")
        expect(
            subject.project(forArgs: "node /Users/tester/scratch/one-off.js") == nil,
            "a path outside any repository must stay unattributed rather than guess"
        )
    }

    private static func testProjectAttributionCachesDirectoryLookups() {
        var probes = 0
        let subject = resolver(repositories: ["/Users/tester/code/app"], probeCount: &probes)
        let args = "node /Users/tester/code/app/node_modules/.bin/metro serve"

        _ = subject.project(forArgs: args)
        let afterFirst = probes
        expect(afterFirst > 0, "the first walk should actually probe the filesystem")

        _ = subject.project(forArgs: args)
        expect(probes == afterFirst, "a repeated lookup should be served from cache so one build's many jobs cost one walk")
    }

    // MARK: - Measurement

    private static func sample(
        _ pid: Int32,
        cpu: Double,
        memory: UInt64 = 0,
        read: UInt64 = 0,
        written: UInt64 = 0
    ) -> RusageSample {
        RusageSample(pid: pid, cpuTimeSeconds: cpu, physicalFootprint: memory, diskBytesRead: read, diskBytesWritten: written)
    }

    /// Keys the samples by their own pid, so a fixture cannot drift from the pid it describes.
    private static func byPID(_ samples: [RusageSample]) -> [Int32: RusageSample] {
        Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
    }

    private static let app = ProjectIdentity(rootPath: "/Users/tester/code/app")

    private static func testProjectRowsMeasureRealDeltas() {
        let processes = [
            CategorizedProcess(pid: 100, project: app, category: .nativeBuild),
            CategorizedProcess(pid: 101, project: app, category: .nativeBuild)
        ]
        let first = byPID([
            sample(100, cpu: 10.0, memory: 900, read: 1_000),
            sample(101, cpu: 5.0, memory: 400, read: 0)
        ])
        let second = byPID([
            sample(100, cpu: 12.0, memory: 1_000, read: 5_000),
            sample(101, cpu: 5.5, memory: 2_000, read: 0)
        ])

        let rows = ProjectLoadRollup.rows(
            processes: processes,
            first: first,
            second: second,
            elapsed: 1,
            coreCount: 8
        )

        expect(rows.count == 1, "processes sharing a project should roll up into one row")
        guard case .measured(let cpu, let memory, let read, let written, let sampled, let total) = rows[0].load else {
            return expect(false, "two complete samples a known interval apart should produce a measured load")
        }
        // 2.5 core-seconds over 1 second is 250% of one core; across 8 cores that is 31.25% of the machine.
        expect(cpu == 31.25, "cpu share should come from the cpu-time delta over the interval, scaled by core count")
        expect(memory == 3_000, "memory should be the summed physical footprint from the later sample")
        expect(read == 4_000, "disk read rate should come from the byte delta over the interval")
        expect(written == 0, "a project doing no writes should report a zero write rate, which is measured, not missing")
        expect(sampled == 2 && total == 2, "a fully sampled project should say so")
        expect(rows[0].categories == [CategoryCount(category: .nativeBuild, count: 2)], "both jobs should count under one category")
    }

    /// A build churns through short-lived jobs, so partial sampling is normal. The row reports how
    /// much of the project it actually saw rather than presenting a floor as a total.
    private static func testProjectRowsExcludeUnmeasurablePIDs() {
        let processes = [
            CategorizedProcess(pid: 100, project: app, category: .nativeBuild),
            CategorizedProcess(pid: 102, project: app, category: .nativeBuild),
            CategorizedProcess(pid: 103, project: app, category: .nativeBuild)
        ]
        let first = byPID([
            sample(100, cpu: 10.0, memory: 1_000),
            sample(102, cpu: 3.0, memory: 500),
            sample(103, cpu: 9.0, memory: 500)
        ])
        let second = byPID([
            sample(100, cpu: 12.0, memory: 1_000),
            // 102 exited between samples and is gone.
            sample(103, cpu: 1.0, memory: 500) // counter went backwards: the pid was reused.
        ])

        let rows = ProjectLoadRollup.rows(processes: processes, first: first, second: second, elapsed: 1, coreCount: 8)

        guard case .measured(let cpu, let memory, _, _, let sampled, let total) = rows[0].load else {
            return expect(false, "one surviving pid is still a real measurement")
        }
        expect(cpu == 25, "only the pid present in both samples should contribute cpu")
        expect(memory == 1_000, "only measurable pids should contribute memory")
        expect(sampled == 1 && total == 3, "the row must disclose that it sampled one of three processes")
    }

    private static func testProjectRowsReportUnavailableRatherThanZero() {
        let processes = [CategorizedProcess(pid: 100, project: app, category: .simulator)]
        let rows = ProjectLoadRollup.rows(
            processes: processes,
            first: byPID([sample(100, cpu: 10.0)]),
            second: [:],
            elapsed: 1,
            coreCount: 8
        )

        expect(rows.count == 1, "a project with categorized work still gets a row even when nothing measured")
        guard case .unavailable = rows[0].load else {
            return expect(false, "a project with no measurable pid must report unavailable, never zero and never a stale value")
        }
        expect(rows[0].categories == [CategoryCount(category: .simulator, count: 1)], "an unmeasured row still names the work it found")
    }

    private static func testProjectRowsOrderHeaviestFirstWithUnattributedLast() {
        let other = ProjectIdentity(rootPath: "/Users/tester/code/other")
        let processes = [
            CategorizedProcess(pid: 100, project: app, category: .nativeBuild),
            CategorizedProcess(pid: 200, project: other, category: .testRunner),
            CategorizedProcess(pid: 300, project: nil, category: .simulator)
        ]
        let first = byPID([sample(100, cpu: 0), sample(200, cpu: 0), sample(300, cpu: 0)])
        let second = byPID([sample(100, cpu: 1.0), sample(200, cpu: 4.0), sample(300, cpu: 8.0)])

        let rows = ProjectLoadRollup.rows(processes: processes, first: first, second: second, elapsed: 1, coreCount: 8)

        expect(rows.count == 3, "each project plus the unattributed bucket should get a row")
        expect(rows[0].project == other, "the heaviest attributed project should sort first")
        expect(rows[1].project == app, "lighter attributed projects follow")
        expect(rows[2].project == nil, "unattributed work sorts last however heavy it is, because it is a gap, not a project")
        expect(rows[2].id == "unattributed", "the unattributed bucket needs a stable identity for the list")
    }

    // MARK: - Capacity grade

    /// Ported from machine-capacity.js evaluateCapacity. Both implementations must grade the same
    /// machine the same way, so these are boundary tests on the shared thresholds.
    private static func testCapacityGradeBands() {
        func assess(
            cpu: Double? = 0,
            heavy: Int = 0,
            thermal: ProcessInfo.ThermalState = .nominal,
            thermalWarning: Bool = false,
            performanceWarning: Bool = false,
            temperature: Double? = nil
        ) -> CapacityAssessment {
            CapacityGrade.assess(CapacityInputs(
                cpuBusyPercent: cpu,
                heatHeavyCount: heavy,
                thermalState: thermal,
                hasThermalWarning: thermalWarning,
                hasPerformanceWarning: performanceWarning,
                cpuTemperatureCelsius: temperature
            ))
        }

        expect(assess().availableCapacity == .high, "a quiet machine has high available capacity")
        expect(assess(cpu: 29.9).availableCapacity == .high, "below the 30% band with no heavy work stays high")
        expect(assess(cpu: 30, heavy: 1).availableCapacity == .moderate, "30% busy alongside heavy work drops to moderate")
        expect(assess(cpu: 29.9, heavy: 1).availableCapacity == .high, "heavy work below the 30% band does not yet reduce capacity")
        expect(assess(cpu: 55).availableCapacity == .moderate, "55% busy alone is moderate")
        expect(assess(heavy: 2).availableCapacity == .moderate, "two heat-heavy jobs are moderate even on a quiet cpu")
        expect(assess(cpu: 55, heavy: 2).availableCapacity == .low, "55% busy with two heavy jobs is low")
        expect(assess(cpu: 80).availableCapacity == .low, "80% busy alone is low")
        expect(assess(thermal: .fair).availableCapacity == .moderate, "a fair thermal state is moderate")
        expect(assess(thermal: .serious).availableCapacity == .low, "a serious thermal state is low")
        expect(assess(thermalWarning: true).availableCapacity == .low, "a recorded thermal warning is low regardless of cpu")
        expect(assess(performanceWarning: true).availableCapacity == .low, "a recorded performance warning is low regardless of cpu")
        expect(assess(temperature: 90).availableCapacity == .low, "the 90C safety ceiling is low")
        expect(assess(cpu: nil).availableCapacity == .high, "an unavailable cpu reading must not invent stress")
        expect(assess(cpu: 80).stress == .high, "low available capacity is reported as high machine stress")
    }
}

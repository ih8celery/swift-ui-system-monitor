import Foundation
import SystemBarKit

/// Tests for the per-project capacity ledger: what kind of work a process is, whose project it
/// belongs to, what its load actually measures, and how the machine is graded overall.
/// Main-actor to match the other plugin suites, which construct plugins.
@MainActor
enum CapacityTests {
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
        testCategorizedProcessesFromTheProcessTable()
        testBusyFilterUsesMeasuredCPUNotLifetimeAverage()
        testUnmeasurableWorkStillCountsAsLoad()
        testBuildsCountByPresenceAndNeverByTheDriversOwnCPU()
        testRepositoryWalkUpIgnoresToolInstallations()
        testRepositoryWalkUpIgnoresHiddenDirectories()
        testListeningPortsCarryTheirProject()
        testThermalWarningParsing()
        testWorkingDirectoryParsing()
        testWorkingDirectoryLookupIsBoundedAndOnlyForUnnamedWork()
        testWorkingDirectoryAttributionNamesBuilds()
        testEvidenceReattributionPreservesTheSplit()
        testListeningPortParsing()
    }

    private static func testListeningPortParsing() {
        let sample = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        node    1234 adam   21u  IPv6 0xabc      0t0  TCP *:3000 (LISTEN)
        Python  2345 adam    7u  IPv4 0xdef      0t0  TCP 127.0.0.1:8000 (LISTEN)
        """
        let ports = CapacityCollector.parseListeningPorts(sample)
        expect(ports.map(\.port) == ["3000", "8000"], "listening port parser should extract port numbers")
        expect(ports.first?.process == "node", "listening port parser should preserve process name")
    }

    // MARK: - Working directory fallback

    /// `lsof -a -d cwd -Fpn` emits a `p<pid>` line then an `n<path>` line per process. One call
    /// covers every pid, so this fallback costs one subprocess per tick rather than one per process.
    private static func testWorkingDirectoryParsing() {
        let output = """
        p864
        fcwd
        n/Users/tester/code/app
        p3782
        fcwd
        n/Users/tester/code/other
        p999
        fcwd
        """
        let directories = CapacityCollector.parseWorkingDirectories(output)

        expect(directories.count == 2, "a process with no path line contributes nothing")
        expect(directories[864] == "/Users/tester/code/app", "the path should attach to the pid above it")
        expect(directories[3782] == "/Users/tester/code/other", "each process set should be read independently")
        expect(directories[999] == nil, "a pid whose cwd could not be read must be absent, not empty")
        expect(CapacityCollector.parseWorkingDirectories("garbage\nn/no/pid/yet").isEmpty, "a path before any pid is ignored")
    }

    private static func testWorkingDirectoryLookupIsBoundedAndOnlyForUnnamedWork() {
        let processes = [
            CategorizedProcess(pid: 1, project: app, category: .bundler),
            CategorizedProcess(pid: 2, project: nil, category: .nativeBuild),
            CategorizedProcess(pid: 3, project: nil, category: .nativeBuild),
            CategorizedProcess(pid: 4, project: nil, category: .nativeBuild)
        ]

        expect(
            CapacityCollector.workingDirectoryLookupPIDs(for: processes, limit: 10) == [2, 3, 4],
            "only work that is not already named needs a lookup"
        )
        expect(
            CapacityCollector.workingDirectoryLookupPIDs(for: processes, limit: 2) == [2, 3],
            "the lookup list is capped so one pathological tick cannot grow unbounded"
        )
    }

    /// The case this fallback exists for: real Swift builds pass relative source paths, so there is
    /// no absolute path in the arguments to walk up from — but the build's working directory is the
    /// repository itself.
    private static func testWorkingDirectoryAttributionNamesBuilds() {
        let compileJob = CategorizedProcess(pid: 2, project: nil, category: .nativeBuild)
        let alreadyNamed = CategorizedProcess(pid: 1, project: app, category: .bundler)
        let strayJob = CategorizedProcess(pid: 3, project: nil, category: .testRunner)

        let attributed = CapacityCollector.attributed(
            [alreadyNamed, compileJob, strayJob],
            workingDirectories: [
                1: "/Users/tester/somewhere/else",
                2: "/Users/tester/code/app",
                3: "/Users/tester/scratch"
            ],
            resolver: resolver(repositories: ["/Users/tester/code/app"])
        )

        expect(attributed.count == 3, "attribution must not drop or reorder work")
        expect(
            attributed[0].project == app,
            "a process already named from its arguments keeps that answer; the cwd is not second-guessed"
        )
        expect(attributed[1].project?.displayName == "app", "a compile job should be named by the repository it runs in")
        expect(attributed[2].project == nil, "a working directory inside no repository still names nothing")
    }

    private static func testEvidenceReattributionPreservesTheSplit() {
        let busyJob = CategorizedProcess(pid: 1, project: nil, category: .bundler)
        let unmeasuredJob = CategorizedProcess(pid: 2, project: nil, category: .nativeBuild)
        let evidence = WorkEvidence(busy: [busyJob], unmeasured: [unmeasuredJob])

        let renamed = evidence.reattributed { processes in
            processes.map { CategorizedProcess(pid: $0.pid, project: app, category: $0.category) }
        }

        expect(renamed.busy.map(\.pid) == [1], "the busy list keeps its membership through reattribution")
        expect(renamed.unmeasured.map(\.pid) == [2], "the unmeasured list keeps its membership through reattribution")
        expect(renamed.busy.first?.project == app, "a newly named busy process carries its project")
        expect(
            renamed.ledgerProcesses.count == 2,
            "an unmeasured process that has just been named now earns a row, which is the whole point"
        )
        expect(renamed.unnamedUnmeasuredCount == 0, "nothing is left unnamed once the fallback succeeded")
    }

    /// A booted simulator runs a hundred idle daemons that all match the simulator pattern, and none
    /// of them is costing anything — but the capacity script's `ps` pcpu gate cannot be reused here,
    /// because pcpu is a lifetime average: a compile job spawned two seconds ago reads near zero
    /// while burning a whole core. So the gate is the measured delta instead.
    private static func testBusyFilterUsesMeasuredCPUNotLifetimeAverage() {
        let idleDaemon = CategorizedProcess(pid: 500, project: nil, category: .simulator)
        let freshTestRun = CategorizedProcess(pid: 501, project: app, category: .testRunner)
        let first = byPID([sample(500, cpu: 400.0), sample(501, cpu: 0.0)])
        let second = byPID([sample(500, cpu: 400.0), sample(501, cpu: 0.9)])

        let measured = ProjectLoadRollup.evidence(
            processes: [idleDaemon, freshTestRun],
            first: first,
            second: second,
            elapsed: 1
        )

        expect(measured.busy.count == 1, "only processes that actually consumed cpu over the interval are busy")
        expect(
            measured.busy.first?.pid == 501,
            "a just-started test run burning most of a core must count, however low its lifetime average reads"
        )
        expect(measured.unmeasured.isEmpty, "both processes were sampled twice, so nothing is unmeasured")
        expect(measured.heatHeavyCount == 1, "a measured idle daemon is evidence of no load and must not raise stress")
    }

    /// Xcode compile jobs are replaced entirely between reads, so their CPU is unknowable. That work
    /// still exists: it must raise machine stress and show as a named row without figures.
    private static func testUnmeasurableWorkStillCountsAsLoad() {
        let buildJob = CategorizedProcess(pid: 501, project: app, category: .nativeBuild)
        let anonymousDaemon = CategorizedProcess(pid: 500, project: nil, category: .simulator)

        let evidence = ProjectLoadRollup.evidence(
            processes: [buildJob, anonymousDaemon],
            first: byPID([sample(500, cpu: 1.0), sample(501, cpu: 1.0)]),
            second: [:],
            elapsed: 1
        )

        expect(evidence.busy.isEmpty, "nothing could be measured, so nothing is busy")
        expect(
            evidence.heatHeavyCount == 2,
            "work that cannot be measured is still work, and must count toward the machine's grade"
        )
        expect(
            evidence.ledgerProcesses.map(\.pid) == [501],
            "only the named unmeasured process earns a row; an anonymous one would claim work on no evidence"
        )
        expect(evidence.unnamedUnmeasuredCount == 1, "what was left out must still be counted so it can be admitted")
    }

    /// The trap the driver creates: `swift-driver` survives a whole build and samples perfectly
    /// cleanly, but it spends that time waiting on children, so its own CPU is a fraction of a
    /// percent. Reporting that as the project's load would understate a busy build enormously while
    /// looking authoritative. A build counts by being there and reports no figures.
    private static func testBuildsCountByPresenceAndNeverByTheDriversOwnCPU() {
        let driver = CategorizedProcess(pid: 600, project: app, category: .nativeBuild)
        let bundler = CategorizedProcess(pid: 601, project: app, category: .bundler)
        // Both sample cleanly. The driver used 0.4% of a core; the bundler used a quarter of one.
        let first = byPID([sample(600, cpu: 10.0, memory: 40_000_000), sample(601, cpu: 5.0, memory: 100_000_000)])
        let second = byPID([sample(600, cpu: 10.004, memory: 40_000_000), sample(601, cpu: 5.25, memory: 100_000_000)])

        let evidence = ProjectLoadRollup.evidence(
            processes: [driver, bundler],
            first: first,
            second: second,
            elapsed: 1
        )

        expect(
            evidence.busy.map(\.pid) == [601],
            "a build driver must never be treated as measured work, however cleanly it sampled"
        )
        expect(evidence.unmeasured.map(\.pid) == [600], "the driver is evidence a build is running")
        expect(evidence.heatHeavyCount == 2, "a running build raises machine stress even with no figure attached")

        let rows = ProjectLoadRollup.rows(
            processes: evidence.ledgerProcesses,
            first: first,
            second: second,
            elapsed: 1,
            coreCount: 8
        )
        expect(rows.count == 1, "the build and the bundler are the same project and share a row")
        guard case .measured(let cpu, let memory, _, _, let sampled, let total) = rows[0].load else {
            return expect(false, "the bundler is measurable, so the project's row still carries figures")
        }
        expect(cpu == 3.125, "only the bundler's cpu counts: the driver's idle time is not the build's cost")
        expect(memory == 100_000_000, "the driver contributes no memory figure either")
        expect(
            sampled == 1 && total == 2,
            "the row must disclose that it measured one of the project's two pieces of work"
        )
        expect(
            rows[0].categories == [
                CategoryCount(category: .nativeBuild, count: 1),
                CategoryCount(category: .bundler, count: 1)
            ],
            "the build is still named as work being done, in declaration order"
        )
    }

    /// Homebrew, rustup and friends install into Git repositories of their own. A tool the machine
    /// happens to keep in Git is not a project the user is working on.
    private static func testRepositoryWalkUpIgnoresToolInstallations() {
        let found = resolver(repositories: ["/opt/homebrew"])
            .repositoryRoot(forPath: "/opt/homebrew/bin/dolt")
        expect(found == nil, "a repository outside the home directory must not become a project")
    }

    private static func testRepositoryWalkUpIgnoresHiddenDirectories() {
        let subject = resolver(repositories: ["/Users/tester/.oh-my-zsh", "/Users/tester/code/app"])
        expect(
            subject.repositoryRoot(forPath: "/Users/tester/.oh-my-zsh/tools/thing.sh") == nil,
            "a repository inside a hidden directory is tooling, not a project"
        )
        expect(
            subject.repositoryRoot(forPath: "/Users/tester/code/app/node_modules/.bin/metro") == "/Users/tester/code/app",
            "a hidden directory below the repository root is fine — only the root's own path matters"
        )
    }

    // MARK: - Collector wiring

    /// The whole live pipeline as pure functions: a `ps` table in, categorized and attributed work
    /// out. Everything that touches the machine stays outside this seam.
    private static func testCategorizedProcessesFromTheProcessTable() {
        let table = """
          412     1   82.5   204800 01:12 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c /Users/tester/code/app/Sources/Thing.swift
          413   412    4.0    51200 00:44 /usr/local/bin/node /Users/tester/code/app/node_modules/.bin/metro serve
          414     1    0.1     2048 04:00 -zsh
          415     1   12.0    32768 00:20 /usr/local/bin/node /Users/tester/elsewhere/serve.js
        """
        let records = ProcessTable.parse(table)
        let work = CapacityCollector.categorizedProcesses(
            in: records,
            resolver: resolver(repositories: ["/Users/tester/code/app"])
        )

        expect(work.count == 2, "only processes matching a work category belong in the ledger")
        expect(!work.contains { $0.pid == 414 }, "a plain shell is not expensive work")
        expect(!work.contains { $0.pid == 415 }, "a node script outside any category is not expensive work")

        let build = work.first { $0.pid == 412 }
        expect(build?.category == .nativeBuild, "the compile job should be categorized as native build work")
        expect(build?.project?.displayName == "app", "the compile job should be attributed by the source path in its args")

        let bundler = work.first { $0.pid == 413 }
        expect(bundler?.category == .bundler, "metro should be categorized as bundler work")
        expect(bundler?.project?.displayName == "app", "both jobs from one repo should attribute to the same project")
    }

    private static func testListeningPortsCarryTheirProject() {
        let table = """
          413     1    4.0    51200 00:44 /usr/local/bin/node /Users/tester/code/app/node_modules/.bin/metro serve
          999     1    0.0     1024 00:10 /usr/sbin/cupsd -l
        """
        let records = ProcessTable.parse(table)
        let ports = [
            DeveloperPort(process: "node", pid: 413, port: "8081", localAddress: "127.0.0.1:8081"),
            DeveloperPort(process: "cupsd", pid: 999, port: "631", localAddress: "*:631"),
            DeveloperPort(process: "ghost", pid: 4242, port: "9000", localAddress: "*:9000")
        ]

        let attributed = CapacityCollector.attributedPorts(
            ports,
            records: records,
            resolver: resolver(repositories: ["/Users/tester/code/app"])
        )

        expect(attributed.count == 3, "attribution must not drop ports it cannot place")
        expect(attributed[0].projectName == "app", "a port served by a project's process should name that project")
        expect(attributed[1].projectName == nil, "a system daemon's port belongs to no project")
        expect(attributed[2].projectName == nil, "a port whose process has already exited cannot be attributed")
    }

    /// Ported from parseThermal in machine-capacity.js: the negated forms must not read as warnings.
    private static func testThermalWarningParsing() {
        let quiet = CapacityCollector.parseThermalWarnings("No thermal warning level has been recorded\nNo performance warning level has been recorded")
        expect(!quiet.hasThermalWarning, "a 'no thermal warning' line must not be read as a warning")
        expect(!quiet.hasPerformanceWarning, "a 'no performance warning' line must not be read as a warning")

        let hot = CapacityCollector.parseThermalWarnings("Thermal warning level has changed to 1")
        expect(hot.hasThermalWarning, "a recorded thermal warning should be detected")
        expect(!hot.hasPerformanceWarning, "a thermal warning alone should not imply a performance warning")

        let throttled = CapacityCollector.parseThermalWarnings("Performance warning level has changed to 2")
        expect(throttled.hasPerformanceWarning, "a recorded performance warning should be detected")
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

        // The driver is the only part of a swiftc build that lives long enough to be traced to a
        // project, so it has to be recognised even though the capacity script's list predates it.
        expect(
            WorkCategory.classify(
                path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver",
                args: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver --driver-mode=swiftc -o SystemBar Sources/App.swift"
            ) == .nativeBuild,
            "a swiftc build driver should classify as native build work"
        )

        expect(!WorkCategory.nativeBuild.isMeasurable, "a native build's cost cannot honestly be measured")
        for category in WorkCategory.allCases where category != .nativeBuild {
            expect(category.isMeasurable, "\(category) runs in long-lived processes and can be measured")
        }
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
            CategorizedProcess(pid: 100, project: app, category: .bundler),
            CategorizedProcess(pid: 101, project: app, category: .bundler)
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
        expect(rows[0].categories == [CategoryCount(category: .bundler, count: 2)], "both jobs should count under one category")
    }

    /// A build churns through short-lived jobs, so partial sampling is normal. The row reports how
    /// much of the project it actually saw rather than presenting a floor as a total.
    private static func testProjectRowsExcludeUnmeasurablePIDs() {
        let processes = [
            CategorizedProcess(pid: 100, project: app, category: .testRunner),
            CategorizedProcess(pid: 102, project: app, category: .testRunner),
            CategorizedProcess(pid: 103, project: app, category: .testRunner)
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

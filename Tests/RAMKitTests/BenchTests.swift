import Foundation
import Testing
@testable import RAMKit

@Suite("Benchmark logic")
struct BenchTests {
    @Test func armOrderIsSeededAndMixed() {
        let a = BenchRunner.order(trials: 20, seed: 20_261_020)
        #expect(a == BenchRunner.order(trials: 20, seed: 20_261_020))
        #expect(a != BenchRunner.order(trials: 20, seed: 7))
        #expect(a.contains(true) && a.contains(false))
    }

    @Test func gateRefusesAShortMachine() {
        var s = fakeSystem()
        s.availablePercent = 14
        #expect(!BenchGate.canStart(s).ok)
        s.availablePercent = 40
        #expect(BenchGate.canStart(s).ok)
        s.pressureLevel = .critical
        #expect(!BenchGate.canStart(s).ok)
        #expect(BenchGate.shouldAbort(s))
        s.pressureLevel = .warn
        s.availablePercent = 9
        #expect(BenchGate.shouldAbort(s))
    }

    func arm(_ name: String, _ mb: Int64, workload: Double? = nil) -> ArmResult {
        ArmResult(arm: name, trial: 1, startedAt: Date(), headlineBytes: mb << 20, grossFreedBytes: mb << 20,
                  swapUsedBefore: 0, swapUsedAfter: 0, compressedBefore: 0, compressedAfter: 0, wallBefore: nil,
                  wallAfter: nil, topApps: [], excludedBusy: [], fixtures: [],
                  workload: workload.map { WorkloadResult(sizeMB: 1024, seconds: $0, gbPerSecond: 1 / $0, swapins: 0,
                                                          swapouts: 10, compressions: 0, decompressions: 0, pageins: 0) })
    }

    @Test func summariesCompareArms() throws {
        let arms = [arm("relief", 600, workload: 1.1), arm("control", 20, workload: 1.6),
                    arm("relief", 650, workload: 1.0), arm("control", -10, workload: 1.5),
                    arm("relief", 700, workload: 1.2), arm("control", 5, workload: 1.7)]
        let s = BenchRunner.summaries(arms)
        let net = try #require(s.first { $0.metric == "net bytes returned" })
        #expect(abs(net.relief.mean - Double(650 << 20)) < 1)
        #expect(try #require(net.welch).p < 0.01)
        #expect(s.contains { $0.metric == "workload seconds" })
    }

    @Test func reportIsGeneratedFromResults() {
        let r = BenchResult(scenario: "real", machine: MachineInfo(model: "Mac17,2", chip: "Apple M5", memoryBytes: 16 << 30, osVersion: "macOS 26.5.2"),
                            startedAt: Date(timeIntervalSince1970: 1_792_460_000), finishedAt: Date(timeIntervalSince1970: 1_792_460_600),
                            holdMs: 10_000, settleMs: 5_000, cooldownS: 60, seed: 1,
                            arms: [arm("relief", 600), arm("control", 20), arm("relief", 640), arm("control", 0)],
                            summaries: BenchRunner.summaries([arm("relief", 600), arm("control", 20), arm("relief", 640), arm("control", 0)]), notes: [])
        let md = BenchReport.markdown([r])
        #expect(md.contains("## real"))
        #expect(md.contains("Apple M5 · 16 GB"))
        #expect(md.contains("| net bytes returned |"))
        #expect(BenchReport.readmeBlock([r]).contains("relief +620.0 MB vs control +10.0 MB"))
    }
}

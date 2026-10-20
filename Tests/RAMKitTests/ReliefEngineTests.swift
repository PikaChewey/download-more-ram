import Foundation
import Testing
@testable import RAMKit

func fakeSystem(swapUsedGB: Double = 9.9, pressure: PressureLevel = .normal) -> SystemSample {
    SystemSample(timestamp: Date(timeIntervalSince1970: 0), physicalBytes: 16 << 30, pageSize: 16384,
                 freeBytes: 100 << 20, activeBytes: 3 << 30, inactiveBytes: 3 << 30, speculativeBytes: 0,
                 wiredBytes: 3 << 30, purgeableBytes: 0, fileBackedBytes: 2 << 30, anonymousBytes: 5 << 30,
                 compressorOccupiedBytes: 5 << 30, compressedUncompressedBytes: 30 << 30,
                 swapTotal: 11 << 30, swapUsed: UInt64(swapUsedGB * 1_073_741_824), swapfileCount: 11,
                 vmVolumeFreeBytes: 93 << 30, swapins: 0, swapouts: 0, pageins: 0, compressions: 0,
                 decompressions: 0, pressureLevel: pressure, availablePercent: 44,
                 compressorPages: 2_090_000, compressorPagesLimit: 6_446_480,
                 compressorSegments: 243_585, compressorSegmentsLimit: 805_810)
}

/// Scripted readings on a virtual clock: sleeping advances time instantly.
final class FakeSampling: Sampling, @unchecked Sendable {
    private let lock = NSLock()
    private var clock: Double = 0
    private var calls = 0
    let script: (Int, Double) -> [ProcessRecord]
    init(script: @escaping (Int, Double) -> [ProcessRecord]) { self.script = script }

    func processSnapshot() -> ProcessSnapshot {
        lock.lock(); defer { lock.unlock() }
        let s = ProcessSnapshot(timestamp: Date(timeIntervalSince1970: clock), records: script(calls, clock))
        calls += 1
        return s
    }
    func systemSample() throws -> SystemSample {
        lock.lock(); defer { lock.unlock() }
        return fakeSystem(swapUsedGB: clock < 2.5 ? 9.9 : 9.1)
    }
    func sleep(ms: Int) async throws { lock.withLock { clock += Double(ms) / 1000 } }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: clock) }
}

struct FakeBackend: ReliefBackend {
    let name = "fake"
    let fail: Bool
    let calls = CallLog()
    final class CallLog: @unchecked Sendable {
        let lock = NSLock()
        var relieved: [(PressureLevel, Int)] = []
    }
    func relieve(level: PressureLevel, holdMs: Int) async throws {
        calls.lock.withLock { calls.relieved.append((level, holdMs)) }
        if fail { throw ReliefError.notPermitted }
    }
    func restore() async throws {}
}

private let ff = "/Applications/Firefox.app/Contents/MacOS/firefox"
private let discord = "/Applications/Discord.app/Contents/MacOS/Discord"

/// Firefox drops a 500 MB content process and Discord shrinks 300 MB once the signal lands (t > 2.5 s).
private func scenario(_ call: Int, _ t: Double) -> [ProcessRecord] {
    let responded = t > 2.5
    var r = [rec(100, name: "firefox", path: ff, mb: 900),
             rec(101, ppid: 100, name: "plugin-container", mb: 2200, resp: 100),
             rec(400, name: "Discord", path: discord, mb: responded ? 400 : 700)]
    if !responded { r.append(rec(102, ppid: 100, name: "plugin-container", mb: 500, resp: 100)) }
    return r
}

@Suite("Relief engine")
struct ReliefEngineTests {
    @Test func producesHonestReceiptAndMonotoneProgress() async throws {
        let sampling = FakeSampling(script: scenario)
        let backend = FakeBackend(fail: false)
        let engine = ReliefEngine(backend: backend, holdMs: 3000, settleMs: 2000, sampling: sampling)
        let log = ProgressLog()
        let receipt = try await engine.run { log.append($0) }

        #expect(receipt.headlineBytes == Int64(800) << 20)
        #expect(receipt.apps.map(\.name) == ["Firefox", "Discord"])
        #expect(receipt.apps[0].exitedMembers == 1)
        #expect(receipt.backend == "fake")
        #expect(receipt.holdMs == 3000)
        #expect(backend.calls.relieved.count == 1)
        #expect(backend.calls.relieved.first?.0 == .critical)
        #expect(receipt.systemAfter.swapUsed < receipt.systemBefore.swapUsed)

        let events = log.all
        #expect(events.first?.phase == .baseline)
        #expect(events.last?.phase == .done)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.elapsed <= $1.elapsed })
        #expect(events.contains { $0.phase == .holding })
        #expect(events.contains { $0.phase == .settling })
        #expect(events.last?.reclaimedSoFar == receipt.headlineBytes)
    }

    @Test func backendFailurePropagates() async {
        let engine = ReliefEngine(backend: FakeBackend(fail: true), holdMs: 1000, settleMs: 500,
                                  sampling: FakeSampling(script: scenario))
        await #expect(throws: ReliefError.notPermitted) { _ = try await engine.run() }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ReliefProgress] = []
    func append(_ p: ReliefProgress) { lock.lock(); items.append(p); lock.unlock() }
    var all: [ReliefProgress] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite("Receipts")
struct ReceiptTests {
    func sample() -> Receipt {
        Receipt(id: "2026-10-20T04-12-03", startedAt: Date(timeIntervalSince1970: 1_792_400_000), durationS: 17.2,
                backend: "helper", level: .critical, holdMs: 10_000,
                machine: MachineInfo(model: "Mac17,2", chip: "Apple M5", memoryBytes: 16 << 30, osVersion: "macOS 26.5.2"),
                headlineBytes: 2_150_000_000, grossFreedBytes: 2_250_000_000,
                apps: [AppDelta(id: 100, name: "Firefox", kind: .app, before: 15_900_000_000, after: 14_060_000_000,
                                busy: false, exitedMembers: 3, newMembers: 0),
                       AppDelta(id: 400, name: "Discord", kind: .app, before: 1_400_000_000, after: 990_000_000,
                                busy: false, exitedMembers: 0, newMembers: 0),
                       AppDelta(id: 500, name: "Mail", kind: .app, before: 300_000_000, after: 400_000_000,
                                busy: false, exitedMembers: 0, newMembers: 0)],
                excludedBusy: [AppDelta(id: 300, name: "Claude Code", kind: .agentSession, before: 12_000_000_000,
                                        after: 9_000_000_000, busy: true, exitedMembers: 1, newMembers: 0)],
                newApps: ["Preview"], goneApps: [], systemBefore: fakeSystem(swapUsedGB: 9.9),
                systemAfter: fakeSystem(swapUsedGB: 8.1), wallBefore: 91, wallAfter: 78)
    }

    @Test func jsonRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ram-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try sample().save(to: dir)
        let loaded = try Receipt.load(url)
        #expect(loaded.headlineBytes == 2_150_000_000)
        #expect(loaded.apps.count == 3)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-10-20T04-12-03.md").path))
        #expect(Receipt.latest(in: dir)?.id == "2026-10-20T04-12-03")
    }

    @Test func markdownTellsTheWholeTruth() {
        let md = sample().markdown()
        #expect(md.hasPrefix("# Downloaded 2.15 GB of RAM"))
        #expect(md.contains("| Firefox | 15.90 GB | 14.06 GB | +1.84 GB |"))
        #expect(md.contains("| Mail | 300.0 MB | 400.0 MB | -100.0 MB |"))
        #expect(md.contains("Not counted (busy): Claude Code +3.00 GB"))
        #expect(md.contains("Preview"))
        #expect(md.contains("wall 91% → 78%"))
        #expect(md.contains("phys_footprint"))
        let firefoxLine = md.range(of: "| Firefox")!.lowerBound
        let discordLine = md.range(of: "| Discord")!.lowerBound
        #expect(firefoxLine < discordLine)
    }
}

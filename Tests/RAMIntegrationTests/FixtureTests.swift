import Darwin
import Foundation
import Testing
@testable import RAMKit

/// Integration tests against real processes. They need `swift build` products (ram-fixture) and a
/// machine that is not already short of memory (skipped below 20% available).
enum Env {
    static let repo: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url
    }()

    static func binary(_ name: String) -> String? {
        for config in ["debug", "release"] {
            let p = repo.appendingPathComponent(".build/arm64-apple-macosx/\(config)/\(name)").path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var signedCLI: String? {
        let p = repo.appendingPathComponent("build/Products.noindex/bin/ram").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static var memoryOK: Bool { (Sysctl.int("kern.memorystatus_level") ?? 0) >= 20 && Sysctl.int("kern.memorystatus_vm_pressure_level") != 4 }
    static var fixturesReady: Bool { binary("ram-fixture") != nil && memoryOK }
}

/// A spawned fixture whose stdout lines are collected as they arrive.
final class Fixture: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var lines: [String] = []
    private var buffer = Data()

    init(_ args: [String]) throws {
        process.executableURL = URL(fileURLWithPath: Env.binary("ram-fixture")!)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.lock.withLock {
                self.buffer.append(d)
                while let nl = self.buffer.firstIndex(of: 10) {
                    self.lines.append(String(decoding: self.buffer[..<nl], as: UTF8.self))
                    self.buffer.removeSubrange(...nl)
                }
            }
        }
        try process.run()
    }

    /// Waits for a line starting with `prefix`; returns the rest of the line.
    func wait(for prefix: String, timeout: Double = 20) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = lock.withLock({ lines.first { $0.hasPrefix(prefix) } }) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            usleep(50_000)
        }
        return nil
    }

    var allLines: [String] { lock.withLock { lines } }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }

    deinit { stop() }
}

@Suite("Fixtures (real processes)", .serialized, .enabled(if: Env.fixturesReady))
struct FixtureTests {
    @Test func samplerSeesACacheHog() throws {
        let hog = try Fixture(["cachehog", "--mb", "256"])
        defer { hog.stop() }
        let pid = try #require(hog.wait(for: "ready").flatMap { Int32($0) })
        let r = try #require(ProcessSampler.record(pid: pid))
        let mib = Double(r.footprint) / 1_048_576
        #expect(abs(mib - 256) < 256 * 0.10 + 8, "footprint \(mib) MiB")
    }

    @Test func orphanIsReparentedAttributedAndQuitSafely() throws {
        let parent = try Fixture(["orphan", "--mb", "32"])
        let child = try #require(parent.wait(for: "child").flatMap { Int32($0) })
        parent.process.waitUntilExit()
        // launchd adopts the child once its parent has exited.
        var record: ProcessRecord?
        for _ in 0..<40 {
            record = ProcessSampler.record(pid: child)
            if record?.ppid == 1 { break }
            usleep(50_000)
        }
        let r = try #require(record)
        #expect(r.ppid == 1)
        #expect(r.responsiblePid != r.pid)     // still attributed to whoever launched it
        #expect(SafeKill.terminate(r, escalate: false) == .ok)
        for _ in 0..<40 where ProcessSampler.record(pid: child) != nil { usleep(50_000) }
        #expect(ProcessSampler.record(pid: child) == nil)
    }

    @Test func leakerGrowthIsVisible() throws {
        let leaker = try Fixture(["leaker", "--mb-per-s", "32", "--seconds", "4"])
        defer { leaker.stop() }
        let pid = try #require(leaker.wait(for: "ready").flatMap { Int32($0) })
        let before = try #require(ProcessSampler.record(pid: pid)).footprint
        _ = leaker.wait(for: "leaked 128", timeout: 15)
        let after = try #require(ProcessSampler.record(pid: pid)).footprint
        let grew = Double(Int64(after) - Int64(before)) / 1_048_576
        #expect(grew > 100, "grew \(grew) MiB")
    }
}

/// End to end with the installed root helper: the kernel's memory-pressure signal reaches a
/// pressure-aware process, which frees its cache, while a process that ignores pressure keeps its
/// memory. Runs the signed CLI (the helper only accepts team-signed callers).
@Suite("Relief end to end (helper)", .serialized,
       .enabled(if: Env.fixturesReady && HelperInstaller.isInstalled && Env.signedCLI != nil))
struct ReliefEndToEndTests {
    @Test func pressureAwareCacheIsReturnedAndDumbHogIsNot() throws {
        let cache = try Fixture(["cachehog", "--mb", "512"])
        let dumb = try Fixture(["dumbhog", "--mb", "512"])
        defer { cache.stop(); dumb.stop() }
        let cachePid = try #require(cache.wait(for: "ready").flatMap { Int32($0) })
        let dumbPid = try #require(dumb.wait(for: "ready").flatMap { Int32($0) })
        let cacheBefore = try #require(ProcessSampler.record(pid: cachePid)).footprint
        let dumbBefore = try #require(ProcessSampler.record(pid: dumbPid)).footprint

        let cli = Process()
        cli.executableURL = URL(fileURLWithPath: Env.signedCLI!)
        cli.arguments = ["download", "--hold", "3", "--json"]
        let out = Pipe()
        cli.standardOutput = out
        try cli.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        cli.waitUntilExit()
        #expect(cli.terminationStatus == 0, "ram download exited \(cli.terminationStatus)")
        let receipt = try Receipt.decoder.decode(Receipt.self, from: data)
        #expect(receipt.backend == "helper")

        #expect(cache.wait(for: "freed", timeout: 5) != nil, "cachehog never saw the pressure event")
        let cacheAfter = try #require(ProcessSampler.record(pid: cachePid)).footprint
        let dumbAfter = try #require(ProcessSampler.record(pid: dumbPid)).footprint
        let returned = Double(Int64(cacheBefore) - Int64(cacheAfter))
        #expect(returned >= 0.9 * 512 * 1_048_576, "cachehog returned \(returned / 1_048_576) MiB")
        let dumbChange = abs(Double(Int64(dumbAfter) - Int64(dumbBefore))) / Double(dumbBefore)
        #expect(dumbChange < 0.05, "dumbhog changed \(dumbChange * 100)%")
        // The kernel is back to reporting real pressure (never stuck at the simulated level).
        #expect(Sysctl.int("kern.memorystatus_vm_pressure_level") != 4 || (Sysctl.int("kern.memorystatus_level") ?? 100) < 35)
        #expect(!ReliefAvailability.interruptedHoldDetected)
    }

    @Test func killingTheClientMidHoldStillRestoresNormal() throws {
        let cli = Process()
        cli.executableURL = URL(fileURLWithPath: Env.signedCLI!)
        cli.arguments = ["download", "--hold", "6", "--json"]
        cli.standardOutput = FileHandle.nullDevice
        cli.standardError = FileHandle.nullDevice
        try cli.run()
        // Wait until the kernel reports the simulated critical level, then kill the client.
        var sawCritical = false
        for _ in 0..<80 {
            if Sysctl.int("kern.memorystatus_vm_pressure_level") == 4 { sawCritical = true; break }
            usleep(100_000)
        }
        kill(cli.processIdentifier, SIGKILL)
        cli.waitUntilExit()
        #expect(sawCritical, "never saw the simulated critical level")
        // The helper finishes the hold on its own and restores normal.
        var restored = false
        for _ in 0..<150 {
            if !ReliefAvailability.interruptedHoldDetected && Sysctl.int("kern.memorystatus_vm_pressure_level") != 4 { restored = true; break }
            usleep(100_000)
        }
        #expect(restored, "pressure still reads critical 15 s after the client died")
    }
}


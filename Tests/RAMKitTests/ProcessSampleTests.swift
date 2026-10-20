import Darwin
import Foundation
import Testing
@testable import RAMKit

@Suite("Process sampler", .serialized)
struct ProcessSampleTests {
    @Test func containsSelf() throws {
        let snap = ProcessSampler.snapshot()
        let me = try #require(snap.records.first { $0.pid == getpid() })
        #expect(me.footprint > 0)
        #expect(me.uid == getuid())
        #expect(me.startTime > 0)
        #expect(me.responsiblePid > 0)
        #expect(snap.record(me.key)?.pid == getpid())
        #expect(snap.totalFootprint >= me.footprint)
    }

    @Test func footprintTracksAllocation() throws {
        let before = try #require(ProcessSampler.snapshot().records.first { $0.pid == getpid() })
        let size = 128 << 20
        let block = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        defer { block.deallocate() }
        // Touch every page with non-zero data so the pages are dirty (zero pages compress away).
        for offset in stride(from: 0, to: size, by: 4096) {
            block.storeBytes(of: UInt64(offset | 1), toByteOffset: offset, as: UInt64.self)
        }
        let after = try #require(ProcessSampler.snapshot().records.first { $0.pid == getpid() })
        let delta = Double(Int64(after.footprint) - Int64(before.footprint))
        #expect(abs(delta - Double(size)) < Double(size) * 0.15, "delta \(delta / 1_048_576) MiB")
    }

    @Test func countsUnreadable() {
        let snap = ProcessSampler.snapshot()
        #expect(snap.unreadableCount >= 0)
        #expect(snap.records.count > 10)
        #expect(snap.listedCount == snap.records.count + snap.unreadableCount + snap.vanishedCount)
    }

    @Test func cwdAndArgvForSelf() throws {
        let cwd = try #require(ProcessSampler.cwd(pid: getpid()))
        #expect(cwd == FileManager.default.currentDirectoryPath)
        let argv = try #require(ProcessSampler.argv(pid: getpid()))
        #expect(!argv.isEmpty)
        #expect(argv[0].contains("swiftpm-testing-helper") || argv[0].contains("xctest")
            || argv[0].hasSuffix("PackageTests"))
    }

    @Test func launchdHasNoReadableFootprintButIsListed() {
        // pid 1 belongs to root: listed by the kernel, unreadable without privileges.
        let snap = ProcessSampler.snapshot()
        if getuid() != 0 { #expect(snap.records.first { $0.pid == 1 } == nil) }
    }
}

import Foundation
import Testing
@testable import RAMKit

@Suite("System sampler")
struct SystemSampleTests {
    @Test func readsPlausibleValues() throws {
        let s = try SystemSampler.read()
        #expect(s.physicalBytes == Sysctl.uint64("hw.memsize"))
        #expect(s.pageSize == UInt64(sysconf(_SC_PAGESIZE)))
        #expect([PressureLevel.normal, .warn, .critical].contains(s.pressureLevel))
        #expect((0...100).contains(s.availablePercent))
        #expect(s.memoryUsedBytes <= s.physicalBytes)
        #expect(s.freeBytes + s.activeBytes + s.inactiveBytes + s.wiredBytes <= s.physicalBytes)
        #expect(s.compressorPagesLimit >= s.compressorPages)
        #expect(s.compressorSegmentsLimit >= s.compressorSegments)
    }

    @Test func swapUsageMatchesSysctl() throws {
        let s = try SystemSampler.read()
        let usage = try #require(Sysctl.swapUsage())
        let diff = Int64(s.swapUsed) - Int64(usage.used)
        #expect(abs(diff) < 64 << 20)
        #expect(s.swapTotal == usage.total)
        #expect(s.swapfileCount >= 0)
        if s.swapTotal > 0 { #expect(s.swapfileCount > 0) }
    }

    @Test func activityMonitorDerivedValues() throws {
        let s = try SystemSampler.read()
        #expect(s.appMemoryBytes == s.anonymousBytes &- min(s.anonymousBytes, s.purgeableBytes))
        #expect(s.memoryUsedBytes == s.appMemoryBytes + s.wiredBytes + s.compressorOccupiedBytes)
        #expect(s.cachedFilesBytes == s.fileBackedBytes + s.purgeableBytes)
    }

    @Test func pressureLevelDecodesKernelValues() {
        #expect(PressureLevel(kernelValue: 1) == .normal)
        #expect(PressureLevel(kernelValue: 2) == .warn)
        #expect(PressureLevel(kernelValue: 4) == .critical)
        #expect(PressureLevel(kernelValue: 0) == .normal)
    }
}

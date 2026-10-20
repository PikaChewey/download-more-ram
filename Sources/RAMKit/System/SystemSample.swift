import CDarwinMem
import Foundation

/// The kernel's memory-pressure level as reported by `kern.memorystatus_vm_pressure_level`
/// (the same values dispatch memory-pressure sources use).
public enum PressureLevel: Int, Codable, Sendable, Comparable {
    case normal = 1
    case warn = 2
    case critical = 4

    public init(kernelValue: Int) {
        switch kernelValue {
        case 4: self = .critical
        case 2: self = .warn
        default: self = .normal
        }
    }

    public var word: String {
        switch self {
        case .normal: "normal"
        case .warn: "warning"
        case .critical: "critical"
        }
    }

    public static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }
}

/// One reading of system-wide memory state. Byte values are page counts times the kernel page
/// size; the derived values match Activity Monitor's Memory tab.
public struct SystemSample: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var physicalBytes: UInt64
    public var pageSize: UInt64

    public var freeBytes: UInt64
    public var activeBytes: UInt64
    public var inactiveBytes: UInt64
    public var speculativeBytes: UInt64
    public var wiredBytes: UInt64
    public var purgeableBytes: UInt64
    public var fileBackedBytes: UInt64
    public var anonymousBytes: UInt64
    /// Physical memory the compressor itself occupies.
    public var compressorOccupiedBytes: UInt64
    /// What the compressed pages would occupy uncompressed.
    public var compressedUncompressedBytes: UInt64

    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var swapfileCount: Int
    public var vmVolumeFreeBytes: UInt64

    public var swapins: UInt64
    public var swapouts: UInt64
    public var pageins: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64

    public var pressureLevel: PressureLevel
    /// `kern.memorystatus_level`: the kernel's percentage of memory still available.
    public var availablePercent: Int

    public var compressorPages: UInt64
    public var compressorPagesLimit: UInt64
    public var compressorSegments: UInt64
    public var compressorSegmentsLimit: UInt64

    /// Activity Monitor "App Memory": anonymous pages that are not purgeable.
    public var appMemoryBytes: UInt64 { anonymousBytes &- min(anonymousBytes, purgeableBytes) }
    /// Activity Monitor "Memory Used": App Memory + Wired + Compressed.
    public var memoryUsedBytes: UInt64 { appMemoryBytes + wiredBytes + compressorOccupiedBytes }
    /// Activity Monitor "Cached Files": file-backed + purgeable pages the kernel can drop.
    public var cachedFilesBytes: UInt64 { fileBackedBytes + purgeableBytes }
    /// Memory the system could hand out without compressing or swapping anything.
    public var headroomBytes: UInt64 { physicalBytes &- min(physicalBytes, memoryUsedBytes) }
}

public enum SystemSamplerError: Error, Sendable {
    case vmStatistics(Int32)
}

public enum SystemSampler {
    public static func read(now: Date = Date()) throws -> SystemSample {
        var vm = dm_vm_stats()
        let kr = dm_vm_read(&vm)
        guard kr == 0 else { throw SystemSamplerError.vmStatistics(kr) }
        let page = vm.page_size
        let swap = Sysctl.swapUsage()
        let prefix = Sysctl.string("vm.swapfileprefix") ?? "/System/Volumes/VM/swapfile"
        let (swapfiles, volumeFree) = swapfileInfo(prefix: prefix)

        return SystemSample(
            timestamp: now,
            physicalBytes: Sysctl.uint64("hw.memsize") ?? 0,
            pageSize: page,
            freeBytes: vm.free_count * page,
            activeBytes: vm.active_count * page,
            inactiveBytes: vm.inactive_count * page,
            speculativeBytes: vm.speculative_count * page,
            wiredBytes: vm.wire_count * page,
            purgeableBytes: vm.purgeable_count * page,
            fileBackedBytes: vm.external_page_count * page,
            anonymousBytes: vm.internal_page_count * page,
            compressorOccupiedBytes: vm.compressor_page_count * page,
            compressedUncompressedBytes: vm.total_uncompressed_pages_in_compressor * page,
            swapTotal: swap?.total ?? 0,
            swapUsed: swap?.used ?? 0,
            swapfileCount: swapfiles,
            vmVolumeFreeBytes: volumeFree,
            swapins: vm.swapins,
            swapouts: vm.swapouts,
            pageins: vm.pageins,
            compressions: vm.compressions,
            decompressions: vm.decompressions,
            pressureLevel: PressureLevel(kernelValue: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1),
            availablePercent: Sysctl.int("kern.memorystatus_level") ?? 0,
            compressorPages: Sysctl.uint64("vm.compressor.pages_compressed")
                ?? Sysctl.uint64("vm.compressor_segment_pages_compressed") ?? 0,
            compressorPagesLimit: Sysctl.uint64("vm.compressor.pages_compressed_limit")
                ?? Sysctl.uint64("vm.compressor_segment_pages_compressed_limit") ?? 0,
            compressorSegments: Sysctl.uint64("vm.compressor.segment.total") ?? 0,
            compressorSegmentsLimit: Sysctl.uint64("vm.compressor.segment.limit") ?? 0
        )
    }

    /// Counts `<prefix><digits>` files (the swapfiles macOS creates on demand) and reports free
    /// space on the volume that holds them.
    static func swapfileInfo(prefix: String) -> (count: Int, volumeFree: UInt64) {
        let url = URL(fileURLWithPath: prefix)
        let dir = url.deletingLastPathComponent().path
        let base = url.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let count = names.filter { name in
            name.hasPrefix(base) && !name.dropFirst(base.count).isEmpty
                && name.dropFirst(base.count).allSatisfy(\.isNumber)
        }.count
        var fs = statfs()
        let free: UInt64 = statfs(dir, &fs) == 0 ? UInt64(fs.f_bavail) * UInt64(fs.f_bsize) : 0
        return (count, free)
    }
}

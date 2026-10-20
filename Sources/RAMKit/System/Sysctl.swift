import CDarwinMem
import Foundation

/// Typed sysctl readers. Reads never need privileges; writes do (see `ReliefBackend`).
public enum Sysctl {
    public struct SwapUsage: Sendable, Equatable {
        public var total: UInt64
        public var used: UInt64
        public var available: UInt64
        public var encrypted: Bool
    }

    public static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        return dm_sysctl_u64(name, &value) == 0 ? value : nil
    }

    public static func int64(_ name: String) -> Int64? {
        var value: Int64 = 0
        return dm_sysctl_i64(name, &value) == 0 ? value : nil
    }

    public static func int(_ name: String) -> Int? {
        int64(name).map { Int($0) }
    }

    public static func string(_ name: String) -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        guard dm_sysctl_string(name, &buf, buf.count) == 0 else { return nil }
        return String(cBuffer: buf)
    }

    public static func swapUsage() -> SwapUsage? {
        var raw = dm_swap_usage()
        guard dm_swap_read(&raw) == 0 else { return nil }
        return SwapUsage(total: raw.total, used: raw.used, available: raw.avail, encrypted: raw.encrypted != 0)
    }

    /// Writes a 32-bit sysctl. Returns 0 or an errno (EPERM when not root).
    static func writeInt32(_ name: String, _ value: Int32) -> Int32 {
        dm_sysctl_write_i32(name, value)
    }
}

extension String {
    /// Decodes a NUL-terminated C buffer as UTF-8 (lossy), stopping at the first NUL.
    init(cBuffer: [CChar]) {
        let bytes = cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}

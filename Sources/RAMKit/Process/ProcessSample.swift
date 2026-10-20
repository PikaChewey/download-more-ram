import CDarwinMem
import Darwin
import Foundation

/// Identifies one process instance across samples: pids get reused, (pid, start time) do not.
public struct ProcessKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var pid: Int32
    public var startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }

    public var description: String { "\(pid)@\(startTime)" }
}

/// One process as seen in a snapshot. `footprint` is phys_footprint: the number Activity
/// Monitor shows in its Memory column (dirty + compressed + swapped memory the process owns).
public struct ProcessRecord: Codable, Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String?
    /// Process start, microseconds since the Unix epoch (0 when the kernel would not say).
    public var startTime: UInt64
    public var footprint: UInt64
    public var lifetimeMaxFootprint: UInt64
    public var residentBytes: UInt64
    public var cpuTimeNs: UInt64
    /// The process macOS holds responsible (the app that launched a helper); self when unknown.
    public var responsiblePid: Int32
    public var coalitionId: UInt64?
    /// `pbi_flags`: includes the pcontrol bits xnu uses at the memory wall (docs/research/xnu.md).
    public var bsdFlags: UInt32 = 0

    public enum PauseAction: String, Codable, Sendable { case none, throttle, suspend, kill }

    /// What macOS will do to this process when it runs out of paging space (PROC_FLAG_PC_*).
    public var pauseAction: PauseAction {
        switch bsdFlags & 0x600 {
        case 0x600: .kill
        case 0x400: .suspend
        case 0x200: .throttle
        default: .none
        }
    }

    /// macOS suspended this process at the memory wall and has not resumed it (PROC_FLAG_PA_SUSP).
    public var pausedByWall: Bool { bsdFlags & 0x1000 != 0 }

    public var id: ProcessKey { key }
    public var key: ProcessKey { ProcessKey(pid: pid, startTime: startTime) }

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, path: String?, startTime: UInt64,
                footprint: UInt64, lifetimeMaxFootprint: UInt64 = 0, residentBytes: UInt64 = 0,
                cpuTimeNs: UInt64 = 0, responsiblePid: Int32, coalitionId: UInt64? = nil, bsdFlags: UInt32 = 0) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.startTime = startTime
        self.footprint = footprint
        self.lifetimeMaxFootprint = lifetimeMaxFootprint
        self.residentBytes = residentBytes
        self.cpuTimeNs = cpuTimeNs
        self.responsiblePid = responsiblePid
        self.coalitionId = coalitionId
        self.bsdFlags = bsdFlags
    }
}

/// Every process the caller is allowed to read, at one instant.
public struct ProcessSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var records: [ProcessRecord]
    /// Listed by the kernel but not readable (other users' processes without root).
    public var unreadableCount: Int
    /// Exited between listing and reading.
    public var vanishedCount: Int
    public var listedCount: Int

    public init(timestamp: Date, records: [ProcessRecord], unreadableCount: Int = 0,
                vanishedCount: Int = 0, listedCount: Int? = nil) {
        self.timestamp = timestamp
        self.records = records
        self.unreadableCount = unreadableCount
        self.vanishedCount = vanishedCount
        self.listedCount = listedCount ?? (records.count + unreadableCount + vanishedCount)
    }

    public var totalFootprint: UInt64 { records.reduce(0) { $0 + $1.footprint } }

    public func record(_ key: ProcessKey) -> ProcessRecord? {
        records.first { $0.pid == key.pid && $0.startTime == key.startTime }
    }

    public var byKey: [ProcessKey: ProcessRecord] {
        Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

public enum ProcessSampler {
    /// Reads every listed process. No subprocesses: libproc + sysctl only.
    public static func snapshot(includePaths: Bool = true, now: Date = Date()) -> ProcessSnapshot {
        let pids = listPids()
        var records: [ProcessRecord] = []
        records.reserveCapacity(pids.count)
        var unreadable = 0
        var vanished = 0

        for pid in pids where pid > 0 {
            switch read(pid: pid, includePath: includePaths) {
            case .success(let record): records.append(record)
            case .failure(.unreadable): unreadable += 1
            case .failure(.vanished): vanished += 1
            }
        }
        return ProcessSnapshot(timestamp: now, records: records, unreadableCount: unreadable,
                               vanishedCount: vanished, listedCount: pids.filter { $0 > 0 }.count)
    }

    public enum ReadFailure: Error, Sendable { case unreadable, vanished }

    /// Re-reads one process (for identity checks before signalling).
    public static func record(pid: Int32) -> ProcessRecord? {
        try? read(pid: pid, includePath: true).get()
    }

    static func read(pid: Int32, includePath: Bool) -> Result<ProcessRecord, ReadFailure> {
        var ru = dm_rusage()
        let err = dm_proc_rusage(pid, &ru)
        if err != 0 { return .failure(err == ESRCH ? .vanished : .unreadable) }
        var bsd = dm_bsdinfo()
        guard dm_proc_bsdinfo(pid, &bsd) == 0 else { return .failure(.vanished) }
        var path: String?
        if includePath {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            if dm_proc_path(pid, &buf, UInt32(buf.count)) > 0 { path = String(cBuffer: buf) }
        }
        let responsible = dm_responsible_pid(pid)
        var coalition: UInt64 = 0
        let hasCoalition = dm_proc_coalition(pid, &coalition) == 0
        return .success(ProcessRecord(
            pid: pid,
            ppid: bsd.ppid,
            uid: bsd.uid,
            name: processName(bsd),
            path: path,
            startTime: bsd.start_sec * 1_000_000 + bsd.start_usec,
            footprint: ru.phys_footprint,
            lifetimeMaxFootprint: ru.lifetime_max_phys_footprint,
            residentBytes: ru.resident_size,
            cpuTimeNs: ru.user_time_ns &+ ru.system_time_ns,
            responsiblePid: responsible > 0 ? responsible : pid,
            coalitionId: hasCoalition ? coalition : nil,
            bsdFlags: bsd.flags
        ))
    }

    /// Interrupt + package-idle wakeups so far (for idle-cost measurement).
    public static func wakeups(pid: Int32) -> UInt64? {
        var ru = dm_rusage()
        guard dm_proc_rusage(pid, &ru) == 0 else { return nil }
        return ru.interrupt_wkups &+ ru.pkg_idle_wkups
    }

    /// The argv of a same-user process (others fail).
    public static func argv(pid: Int32) -> [String]? {
        var raw: UnsafeMutablePointer<CChar>?
        var len = 0
        let argc = dm_proc_argv(pid, &raw, &len)
        guard argc >= 0, let raw else { return nil }
        defer { free(raw) }
        let data = Data(bytes: raw, count: len)
        let parts = data.split(separator: 0, omittingEmptySubsequences: false)
            .prefix(Int(argc))
            .map { String(decoding: $0, as: UTF8.self) }
        return Array(parts)
    }

    /// The value of one environment variable of a same-user process (nothing else is read out).
    public static func env(pid: Int32, name: String) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard dm_proc_env(pid, name, &buf, buf.count) == 0 else { return nil }
        return String(cBuffer: buf)
    }

    /// The current working directory of a same-user process.
    public static func cwd(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        guard dm_proc_cwd(pid, &buf, UInt32(buf.count)) == 0 else { return nil }
        let s = String(cBuffer: buf)
        return s.isEmpty ? nil : s
    }

    static func listPids() -> [Int32] {
        var capacity = Int(dm_list_pids(nil, 0)) + 64
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let n = Int(dm_list_pids(&pids, Int32(capacity)))
            if n < 0 { return [] }
            if n < capacity { return Array(pids.prefix(n)) }
            capacity *= 2
        }
    }

    private static func processName(_ bsd: dm_bsdinfo) -> String {
        var info = bsd
        let name = withUnsafeBytes(of: &info.name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        if !name.isEmpty { return name }
        return withUnsafeBytes(of: &info.comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

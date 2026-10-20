import Darwin
import Foundation

/// Everything a download can do besides the kernel signal. Each lever runs on its own, measured by
/// its own before/after snapshot pair of the processes it targets, so a receipt can say exactly
/// where every byte came from. Levers that end processes only run when the user allowed them.
public enum LeverKind: String, Codable, Sendable, CaseIterable {
    case kernelSignal = "signal"
    case firefoxGPU = "firefox-gpu"
    case leftovers
    case archivedSessions = "archived"
    case resumePaused = "resume"

    public var title: String {
        switch self {
        case .kernelSignal: "macOS memory-pressure signal"
        case .firefoxGPU: "Restart Firefox's GPU process"
        case .leftovers: "Quit servers agents left behind"
        case .archivedSessions: "Quit archived agent sessions"
        case .resumePaused: "Resume apps macOS paused"
        }
    }

    /// Levers that end or restart processes need the user's yes; the signal and resume do not.
    public var needsConsent: Bool { self == .firefoxGPU || self == .leftovers || self == .archivedSessions }

    /// `ram download --levers firefox-gpu,leftovers` (the signal always runs first).
    public static func parse(_ text: String?) -> Result<[LeverKind], InputError> {
        guard let text, !text.isEmpty else { return .success([]) }
        var out: [LeverKind] = []
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part == "all" { out = LeverKind.allCases.filter { $0 != .kernelSignal }; continue }
            guard let k = LeverKind(rawValue: part), k != .kernelSignal else {
                return .failure(InputError("unknown lever \"\(part)\" (use firefox-gpu, leftovers, archived, resume or all)"))
            }
            if !out.contains(k) { out.append(k) }
        }
        return .success(out)
    }
}

/// What one lever did. `bytes` is nil for actions that are not about memory (resuming paused apps).
public struct LeverResult: Codable, Sendable, Equatable {
    public var kind: LeverKind
    public var title: String
    public var bytes: Int64?
    public var targets: [String]
    public var detail: String?
    public var durationS: Double
}

/// A lever that could run now, with an estimate of what it would return (for "also available").
public struct LeverOffer: Codable, Sendable, Equatable {
    public var kind: LeverKind
    public var estimateBytes: UInt64?
    public var reason: String
}

/// The side effects a lever needs, injectable so tests never touch real processes.
public protocol LeverActions: Sendable {
    func terminate(_ r: ProcessRecord) -> KillResult
    func restartFirefoxGPU(_ r: ProcessRecord) -> FirefoxLevers.GPURestart
    func resume(pid: Int32) async -> Bool
}

public struct LiveLeverActions: LeverActions {
    public init() {}
    public func terminate(_ r: ProcessRecord) -> KillResult { SafeKill.terminate(r, escalate: false) }
    public func restartFirefoxGPU(_ r: ProcessRecord) -> FirefoxLevers.GPURestart { FirefoxLevers.restartGPU(r) }
    public func resume(pid: Int32) async -> Bool {
        if geteuid() == 0, case .success = PausedApps.resume(pid: pid) { return true }
        return (try? await HelperBackend().resumePaused(pid: pid)) != nil
    }
}

public enum LeverPlanner {
    public static let gpuMinBytes: UInt64 = 1 << 30

    /// What each lever would touch right now.
    public static func offers(snapshot s: ProcessSnapshot, sessions: [AgentSession], leftovers: [Leftover],
                              wall: WallStatus?, now: Date = Date()) -> [LeverOffer] {
        var out: [LeverOffer] = []
        if let gpu = FirefoxLevers.gpuProcess(in: s), gpu.footprint >= gpuMinBytes {
            out.append(LeverOffer(kind: .firefoxGPU, estimateBytes: gpu.footprint,
                                  reason: "Firefox's GPU process holds \(Format.bytes(gpu.footprint)); Firefox relaunches it (WebGL/canvas reset)"))
        }
        if !leftovers.isEmpty {
            let bytes = leftovers.reduce(UInt64(0)) { $0 + $1.record.footprint }
            out.append(LeverOffer(kind: .leftovers, estimateBytes: bytes,
                                  reason: "\(leftovers.count) orphaned process\(leftovers.count == 1 ? "" : "es") your agents forgot"))
        }
        let archived = sessions.filter { AgentClassifier.safeToQuitArchived($0, now: now) }
        if !archived.isEmpty {
            let bytes = archived.reduce(UInt64(0)) { $0 + $1.footprint }
            out.append(LeverOffer(kind: .archivedSessions, estimateBytes: bytes,
                                  reason: "\(archived.count) agent session\(archived.count == 1 ? "" : "s") archived in Claude, still running"))
        }
        let paused = s.records.filter(\.pausedByWall)
        if !paused.isEmpty, PausedApps.safeToResume(wall, system: nil) {
            out.append(LeverOffer(kind: .resumePaused, estimateBytes: nil,
                                  reason: "\(paused.count) process\(paused.count == 1 ? "" : "es") macOS paused at the memory wall"))
        }
        return out
    }
}

/// A process a quitting lever would act on right now: the CLI lists these and asks before it runs.
public struct QuitTarget: Sendable, Equatable {
    public var kind: LeverKind
    public var record: ProcessRecord
    public var why: String
}

public enum LeverPreview {
    /// The same selection `LeverRunner` makes (leftovers; heads of archived, quiet sessions).
    public static func targets(_ kinds: [LeverKind], sessions: [AgentSession], leftovers: [Leftover]) -> [QuitTarget] {
        var out: [QuitTarget] = []
        if kinds.contains(.leftovers) {
            out += leftovers.map { QuitTarget(kind: .leftovers, record: $0.record, why: "leftover: \($0.reason)") }
        }
        if kinds.contains(.archivedSessions) {
            for s in sessions where AgentClassifier.safeToQuitArchived(s) {
                guard let head = s.members.first(where: { $0.pid == s.id }) else { continue }
                out.append(QuitTarget(kind: .archivedSessions, record: head, why: "archived session \"\(s.title ?? s.label)\""))
            }
        }
        return out
    }
}

/// Runs the non-signal levers one after another, each with its own before/after measurement.
public struct LeverRunner: Sendable {
    let sampling: any Sampling
    let actions: any LeverActions
    let settleMs: Int

    public init(sampling: any Sampling = LiveSampling(), actions: any LeverActions = LiveLeverActions(), settleMs: Int = 6_000) {
        self.sampling = sampling
        self.actions = actions
        self.settleMs = settleMs
    }

    /// `forceResume`: the user named `resume` itself, so paused apps are resumed even near the wall
    /// (as `ram resume` does); otherwise resuming waits until the wall is not near.
    public func run(_ kinds: [LeverKind], sessions: [AgentSession], leftovers: [Leftover], wall: WallStatus?,
                    forceResume: Bool = false) async throws -> [LeverResult] {
        var results: [LeverResult] = []
        for kind in kinds where kind != .kernelSignal {
            let start = sampling.now()
            switch kind {
            case .firefoxGPU:
                let before = sampling.processSnapshot()
                guard let gpu = FirefoxLevers.gpuProcess(in: before), gpu.footprint >= LeverPlanner.gpuMinBytes else {
                    results.append(LeverResult(kind: kind, title: kind.title, bytes: nil, targets: [], detail: "skipped: GPU process under 1 GB", durationS: 0))
                    continue
                }
                let group = gpu.responsiblePid
                let fp0 = Self.groupFootprint(before, responsible: group)
                let outcome = actions.restartFirefoxGPU(gpu)
                guard outcome == .restarted else {
                    results.append(LeverResult(kind: kind, title: kind.title, bytes: nil, targets: ["Firefox"], detail: "skipped: \(outcome)", durationS: 0))
                    continue
                }
                try await sampling.sleep(ms: settleMs)
                let after = sampling.processSnapshot()
                let fp1 = Self.groupFootprint(after, responsible: group)
                let newGPU = FirefoxLevers.gpuProcess(in: after)
                results.append(LeverResult(kind: kind, title: kind.title, bytes: Int64(fp0) - Int64(fp1), targets: ["Firefox"],
                                           detail: "GPU process \(Format.bytes(gpu.footprint)) → \(newGPU.map { Format.bytes($0.footprint) } ?? "relaunching")",
                                           durationS: sampling.now().timeIntervalSince(start)))
            case .leftovers, .archivedSessions:
                let targets: [ProcessRecord] = kind == .leftovers
                    ? leftovers.map(\.record)
                    : sessions.filter { AgentClassifier.safeToQuitArchived($0) }.flatMap(\.members)
                guard !targets.isEmpty else {
                    results.append(LeverResult(kind: kind, title: kind.title, bytes: nil, targets: [], detail: "nothing to quit", durationS: 0))
                    continue
                }
                let before = sampling.processSnapshot().byKey
                let heads: [ProcessRecord] = kind == .leftovers
                    ? targets
                    : sessions.filter { AgentClassifier.safeToQuitArchived($0) }.compactMap { s in s.members.first { $0.pid == s.id } }
                var quit: [String] = []
                for r in heads where actions.terminate(r) == .ok { quit.append(r.name) }
                try await sampling.sleep(ms: min(settleMs, 3_000))
                let after = sampling.processSnapshot().byKey
                // Only the targeted processes: an exited one returns its whole footprint, a survivor its change.
                var bytes: Int64 = 0
                for t in targets {
                    guard let b = before[t.key] else { continue }
                    bytes += Int64(b.footprint) - Int64(after[t.key]?.footprint ?? 0)
                }
                results.append(LeverResult(kind: kind, title: kind.title, bytes: bytes, targets: quit,
                                           detail: "\(quit.count) quit", durationS: sampling.now().timeIntervalSince(start)))
            case .resumePaused:
                let paused = sampling.processSnapshot().records.filter(\.pausedByWall)
                if !paused.isEmpty && !forceResume && !PausedApps.safeToResume(wall, system: nil) {
                    results.append(LeverResult(kind: kind, title: kind.title, bytes: nil, targets: [],
                                               detail: "skipped: the wall is still near (ram resume does it anyway)", durationS: 0))
                    continue
                }
                var resumed: [String] = []
                for r in paused where await actions.resume(pid: r.pid) { resumed.append(r.name) }
                results.append(LeverResult(kind: kind, title: kind.title, bytes: nil, targets: resumed,
                                           detail: "\(resumed.count) of \(paused.count) resumed", durationS: sampling.now().timeIntervalSince(start)))
            case .kernelSignal:
                break
            }
        }
        return results
    }

    static func groupFootprint(_ s: ProcessSnapshot, responsible: Int32) -> UInt64 {
        s.records.filter { $0.responsiblePid == responsible }.reduce(0) { $0 + $1.footprint }
    }
}

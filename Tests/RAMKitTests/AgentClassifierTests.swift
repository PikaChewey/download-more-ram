import Darwin
import Foundation
import Testing
@testable import RAMKit

private let claudeCLI = "/Users/bryan/Library/Application Support/Claude/claude-code/2.1.299/4fa9694b7975/claude.app/Contents/MacOS/claude"
private let python = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"

struct FakeInfo: ProcessInfoSource {
    var cwds: [Int32: String] = [:]
    var argvs: [Int32: [String]] = [:]
    func cwd(pid: Int32) -> String? { cwds[pid] }
    func argv(pid: Int32) -> [String]? { argvs[pid] }
}

@Suite("Agent attribution and leftovers")
struct AgentClassifierTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func t(_ secondsAgo: Double) -> UInt64 { UInt64((1_000_000 - secondsAgo) * 1_000_000) }

    func renderSnapshot() -> ProcessSnapshot {
        ProcessSnapshot(timestamp: now, records: [
            rec(57329, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude", mb: 919, start: t(300_000)),
            rec(58412, ppid: 57329, name: "disclaimer", path: "/Applications/Claude.app/Contents/Helpers/disclaimer", mb: 1, resp: 57329, start: t(299_000)),
            rec(58413, ppid: 58412, name: "claude", path: claudeCLI, mb: 431, cpuNs: 50_000_000_000, start: t(299_000)),
            rec(95814, ppid: 95812, name: "Blender", path: "/Applications/Blender.app/Contents/MacOS/Blender", mb: 1748, resp: 58413, start: t(99)),
            rec(95813, ppid: 95811, name: "Blender", path: "/Applications/Blender.app/Contents/MacOS/Blender", mb: 1718, resp: 58413, start: t(99)),
            rec(95834, ppid: 95827, name: "ffmpeg", path: "/opt/homebrew/bin/ffmpeg", mb: 1603, resp: 58413, start: t(90)),
            rec(68968, ppid: 1, name: "Python", path: python, mb: 11, resp: 58413, cpuNs: 400_000_000, start: t(3 * 3600 + 1368)),
            rec(70000, ppid: 1, name: "Rectangle", path: "/Applications/Rectangle.app/Contents/MacOS/Rectangle", mb: 40, start: t(90_000)),
            rec(70001, ppid: 1, name: "node", path: "/opt/homebrew/bin/node", mb: 120, cpuNs: 10_000_000, start: t(7200)),
        ])
    }

    var info: FakeInfo {
        FakeInfo(cwds: [58413: "/Users/bryan/Library/Application Support/Claude/scratch-workspaces/c4ac/878f/scratch-2026-10-16-352c15"],
                 argvs: [68968: [python, "-m", "http.server", "8765", "--bind", "127.0.0.1"],
                         70001: ["/opt/homebrew/bin/node", "/Users/bryan/tools/menubar-helper.js"]])
    }

    @Test func claudeSessionCollectsItsWork() throws {
        var cpu = CPUHistory()
        cpu.add(renderSnapshot())
        let sessions = AgentClassifier.sessions(renderSnapshot(), cpuHistory: cpu, info: info, now: now)
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.tool == .claudeCode)
        #expect(s.host == "Claude")
        #expect(s.label == "scratch-2026-10-16-352c15")
        #expect(s.footprint == UInt64(431 + 1748 + 1718 + 1603 + 11) << 20)
        #expect(s.topChildren == "Blender ×2, ffmpeg, Python")
    }

    @Test func orphanedHttpServerIsALeftover() throws {
        let left = AgentClassifier.leftovers(renderSnapshot(), cpuHistory: CPUHistory(), info: info, now: now)
        #expect(left.map(\.record.pid) == [68968])
        let l = try #require(left.first)
        #expect(l.reason.contains("http.server"))
        #expect(l.reason.contains("Claude Code"))
        #expect(l.idleS >= 3 * 3600)
    }

    @Test func appsAndLaunchdJobsAreNeverLeftovers() {
        // Rectangle (.app, ppid 1) and a node helper that is its own responsible process (a launchd job).
        let left = AgentClassifier.leftovers(renderSnapshot(), cpuHistory: CPUHistory(), info: info, now: now)
        #expect(!left.contains { $0.record.pid == 70000 })
        #expect(!left.contains { $0.record.pid == 70001 })
    }

    @Test func busyOrphanIsNotALeftover() {
        var snap = renderSnapshot()
        let i = snap.records.firstIndex { $0.pid == 68968 }!
        snap.records[i].cpuTimeNs = 2_000_000_000_000   // 2000 s of CPU in 3.4 h: working, not idle
        #expect(AgentClassifier.leftovers(snap, cpuHistory: CPUHistory(), info: info, now: now).isEmpty)
    }

    @Test func cpuHistoryTracksIdleTime() {
        var h = CPUHistory()
        let key = ProcessKey(pid: 5, startTime: 1)
        func s(_ t: Double, cpu: UInt64) -> ProcessSnapshot {
            ProcessSnapshot(timestamp: Date(timeIntervalSince1970: t),
                            records: [rec(5, name: "x", mb: 1, cpuNs: cpu, start: 1)])
        }
        h.add(s(0, cpu: 100))
        h.add(s(60, cpu: 900_000_000))      // active at t=60
        h.add(s(600, cpu: 900_000_100))     // +100 ns is noise, still idle since 60
        #expect(h.idleSeconds(key, now: Date(timeIntervalSince1970: 600)) == 540)
    }
}

@Suite("Safe quit")
struct SafeKillTests {
    @Test func refusesOtherUsersProtectedAndChangedIdentity() {
        let other = rec(1, uid: 0, name: "launchd", mb: 10)
        #expect(SafeKill.check(other, current: other) == .refused(.otherUser))
        let ws = rec(402, uid: getuid(), name: "WindowServer", mb: 2000)
        #expect(SafeKill.check(ws, current: ws) == .refused(.protected("WindowServer")))
        let old = rec(68968, uid: getuid(), name: "Python", mb: 11, start: 100)
        let reused = rec(68968, uid: getuid(), name: "Python", mb: 11, start: 200)
        #expect(SafeKill.check(old, current: reused) == .refused(.identityChanged))
        #expect(SafeKill.check(old, current: nil) == .refused(.notFound))
        #expect(SafeKill.check(old, current: old) == .ok)
    }

    @Test func neverSignalsItself() {
        let me = rec(getpid(), uid: getuid(), name: "ram", mb: 10)
        #expect(SafeKill.check(me, current: me) == .refused(.protected("ram")))
    }

    @Test func terminatesARealChildProcess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        let r = try #require(ProcessSampler.record(pid: p.processIdentifier))
        #expect(SafeKill.terminate(r, escalate: false) == .ok)
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal)
        #expect(p.terminationStatus == SIGTERM)
    }
}

@Suite("Agent detection")
struct AgentToolTests {
    @Test func desktopAppsAreNotSessions() {
        #expect(AgentTool.detect(name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude") == nil)
        #expect(AgentTool.detect(name: "claude", path: "/Users/b/.local/bin/claude") == .claudeCode)
        #expect(AgentTool.detect(name: "codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex") == .codex)
        #expect(AgentTool.detect(name: "node", path: "/opt/homebrew/bin/node",
                                 argv: ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"]) == .gemini)
        #expect(AgentTool.detect(name: "node", path: "/opt/homebrew/bin/node", argv: ["node", "server.js"]) == nil)
    }
}

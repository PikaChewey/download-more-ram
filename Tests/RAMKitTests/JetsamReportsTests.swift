import Darwin
import Foundation
import Testing
@testable import RAMKit

@Suite("macOS crisis reports (JetsamEvent)")
struct JetsamReportsTests {
    static let page = 16_384

    static func proc(_ name: String, pid: Int, coalition: Int?, age: Int, pages: Int, reason: String? = nil) -> [String: Any] {
        var p: [String: Any] = ["name": name, "pid": pid, "age": age, "rpages": pages, "states": [String]()]
        if let coalition { p["coalition"] = coalition }
        if let reason { p["reason"] = reason; p["killDelta"] = 1000 }
        return p
    }

    /// A report shaped like the real ones: a one-line header, then the body.
    static func report(date: String, processes: [[String: Any]], largest: String = "python3.12") -> Data {
        let header = #"{"bug_type":"298","timestamp":"\#(date)","os_version":"macOS 26.5.2 (25F84)"}"#
        let body: [String: Any] = [
            "date": date, "bug_type": "298", "largestProcess": largest,
            "memoryStatus": ["pageSize": page, "compressorSize": 10, "uncompressed": 100,
                             "memoryPages": ["free": 1, "active": 2]],
            "processes": processes,
        ]
        return Data((header + "\n").utf8) + (try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]))
    }

    static var crisis: [[String: Any]] { [
        proc("Claude", pid: 900, coalition: 7, age: 9_000, pages: 1_000),
        proc("python3.12", pid: 50, coalition: 7, age: 10, pages: 65_536),
        proc("python3.12", pid: 51, coalition: 7, age: 11, pages: 65_536),
        proc("python3.12", pid: 52, coalition: 7, age: 12, pages: 65_536),
        proc("firefox", pid: 400, coalition: 8, age: 8_000, pages: 100),
        proc("plugin-container", pid: 401, coalition: 8, age: 5, pages: 200),
        proc("loner", pid: 77, coalition: nil, age: 1, pages: 3),
        proc("cfprefsd", pid: 601, coalition: 2, age: 1, pages: 50, reason: "jettisoned"),
        proc("cfprefsd", pid: 602, coalition: 2, age: 1, pages: 50, reason: "jettisoned"),
        proc("cfprefsd", pid: 603, coalition: 2, age: 1, pages: 50, reason: "jettisoned"),
        proc("trustd", pid: 604, coalition: 3, age: 1, pages: 20, reason: "vm-compressor-space-shortage"),
    ] }

    @Test func parsesWhoHeldMemoryAndWhoWasKilled() throws {
        let r = try #require(JetsamReports.parse(Self.report(date: "2026-10-16 04:08:04.11 -0400", processes: Self.crisis),
                                                 file: "JetsamEvent-2026-10-16-040804.ips"))
        #expect(r.largestProcess == "python3.12")
        #expect(r.date == ISO8601DateFormatter().date(from: "2026-10-16T08:08:04Z"))
        // The app is named after its oldest process and owns everything it launched.
        let claude = try #require(r.apps.first)
        #expect(claude.name == "Claude")
        #expect(claude.processes == 4)
        #expect(claude.bytes == UInt64(1_000 + 3 * 65_536) * UInt64(Self.page))
        #expect(claude.biggest == JetsamReport.NameGroup(name: "python3.12", count: 3, bytes: UInt64(3 * 65_536 * Self.page)))
        #expect(r.apps[1].name == "firefox" && r.apps[1].processes == 2)
        // Killed processes are not counted as holding memory.
        #expect(!r.apps.contains { $0.name == "cfprefsd" || $0.name == "trustd" })
        #expect(r.apps.contains { $0.name == "loner" && $0.processes == 1 })
        #expect(r.killed == 4)
        #expect(r.killReasons == ["jettisoned": 3, "vm-compressor-space-shortage": 1])
        #expect(r.mostKilled.first == JetsamReport.NameGroup(name: "cfprefsd", count: 3, bytes: UInt64(150 * Self.page)))
        #expect(r.compressorBytes == UInt64(10 * Self.page))
        #expect(r.compressedDataBytes == UInt64(100 * Self.page))
    }

    @Test func fractionalSecondsOfAnyLengthParse() {
        #expect(JetsamReports.reportDate("2026-10-17 17:24:48.32 -0400") == JetsamReports.reportDate("2026-10-17 17:24:48 -0400"))
        #expect(JetsamReports.reportDate("2026-10-17 17:24:48.321 -0400") != nil)
        #expect(JetsamReports.reportDate("yesterday") == nil)
    }

    @Test func rejectsWhatIsNotAReport() {
        #expect(JetsamReports.parse(Data("not json\n{}".utf8), file: "x") == nil)
        #expect(JetsamReports.parse(Data(#"{"bug_type":"298"}"#.utf8), file: "x") == nil)
        #expect(JetsamReports.parse(Data(), file: "x") == nil)
    }

    @Test func nearbyReportsAreOneCrisis() throws {
        func r(_ date: String, pythonPages: Int, kills: Int) throws -> JetsamReport {
            var ps = [Self.proc("Claude", pid: 1, coalition: 7, age: 9, pages: 10),
                      Self.proc("python3.12", pid: 2, coalition: 7, age: 1, pages: pythonPages)]
            for i in 0..<kills { ps.append(Self.proc("cfprefsd", pid: 100 + i, coalition: 2, age: 1, pages: 1, reason: "jettisoned")) }
            return try #require(JetsamReports.parse(Self.report(date: date, processes: ps), file: date))
        }
        let reports = [try r("2026-10-16 04:02:26.00 -0400", pythonPages: 100, kills: 5),
                       try r("2026-10-16 04:13:00.00 -0400", pythonPages: 900, kills: 7),
                       try r("2026-10-16 12:07:06.00 -0400", pythonPages: 50, kills: 1)]
        let eps = JetsamReports.episodes(reports.reversed())
        #expect(eps.count == 2)
        #expect(eps[0].reports == 2 && eps[0].killed == 12)
        #expect(eps[0].killReasons == ["jettisoned": 12])
        #expect(eps[0].mostKilled.first?.count == 12)
        #expect(eps[0].peak.date == reports[1].date)  // python was biggest in the second report
        #expect(eps[0].end.timeIntervalSince(eps[0].start) == 634)
        #expect(eps[1].reports == 1 && eps[1].killed == 1)
        #expect(JetsamReports.episodes([]).isEmpty)
    }

    @Test func crisisCountsAddUpEveryReportNotJustEachTopThree() throws {
        func kills(_ names: [(String, Int)]) -> [[String: Any]] {
            var ps: [[String: Any]] = [Self.proc("Claude", pid: 1, coalition: 7, age: 9, pages: 10)]
            var pid = 100
            for (n, c) in names { for _ in 0..<c { pid += 1; ps.append(Self.proc(n, pid: pid, coalition: 2, age: 1, pages: 1, reason: "jettisoned")) } }
            return ps
        }
        // trustd is 4th (not shown) in the first report but first overall.
        let a = try #require(JetsamReports.parse(Self.report(date: "2026-10-16 04:02:26.00 -0400",
            processes: kills([("a", 5), ("b", 5), ("c", 5), ("trustd", 4)])), file: "a"))
        let b = try #require(JetsamReports.parse(Self.report(date: "2026-10-16 04:04:00.00 -0400",
            processes: kills([("trustd", 9)])), file: "b"))
        #expect(!a.mostKilled.contains { $0.name == "trustd" })
        let e = try #require(JetsamReports.episodes([a, b]).first)
        #expect(e.mostKilled.first == JetsamReport.NameGroup(name: "trustd", count: 13, bytes: UInt64(13 * Self.page)))
        #expect(e.killed == 28)
        // The per-name table stays out of JSON.
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        #expect(!json.contains("killedByName"))
    }

    @Test func loadsRecentReportsOnlyAndCountsUnreadableOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jetsam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = try #require(JetsamReports.fileDate("JetsamEvent-2026-10-20-120000.ips"))
        try Self.report(date: "2026-10-16 04:08:04.11 -0400", processes: Self.crisis)
            .write(to: dir.appendingPathComponent("JetsamEvent-2026-10-16-040804.ips"))
        try Self.report(date: "2026-09-01 04:08:04.11 -0400", processes: Self.crisis)
            .write(to: dir.appendingPathComponent("JetsamEvent-2026-09-01-040804.ips"))  // older than the window
        try Data("{}".utf8).write(to: dir.appendingPathComponent("firefox_2026-10-16-140908_MacBook.diag"))
        let locked = dir.appendingPathComponent("JetsamEvent-2026-10-17-172448.ips")
        try Self.report(date: "2026-10-17 17:24:48.32 -0400", processes: Self.crisis).write(to: locked)
        chmod(locked.path, 0)

        let (reports, unreadable) = JetsamReports.load(days: 7, directory: dir.path, now: now)
        if geteuid() == 0 {
            #expect(reports.count == 2 && unreadable == 0)  // root reads anything
        } else {
            #expect(reports.map(\.file) == ["JetsamEvent-2026-10-16-040804.ips"])
            #expect(unreadable == 1)
        }
        #expect(JetsamReports.load(days: 7, directory: dir.path + "/missing", now: now).reports.isEmpty)
    }

    @Test func doctorNamesTheAppAndItsBiggestGroup() throws {
        let r = try #require(JetsamReports.parse(Self.report(date: "2026-10-16 04:08:04.11 -0400", processes: Self.crisis), file: "f"))
        let text = Render.crisisReports(JetsamReports.episodes([r]), unreadable: 0,
                                        appNames: ["firefox": "Firefox"], style: Render.Style(color: false))
        #expect(text.contains("What filled memory"))
        #expect(text.contains("macOS killed 4 background processes (memory was short; the compressor ran out of space); cfprefsd 3×"))
        #expect(JetsamReports.mainReasons(["jettisoned": 90, "idle-exit": 10]) == ["jettisoned"])
        #expect(text.contains("python3.12 ×3"))
        #expect(text.contains("Firefox"))
        #expect(Render.crisisReports([], unreadable: 3, appNames: [:], style: Render.Style(color: false)).contains("3 macOS crisis reports"))
        #expect(Render.crisisReports([], unreadable: 0, appNames: [:], style: Render.Style(color: false)).isEmpty)
    }
}

import Foundation
import Testing
@testable import RAMKit

func rec(_ pid: Int32, ppid: Int32 = 1, uid: UInt32 = 501, name: String, path: String? = nil,
         mb: UInt64, resp: Int32? = nil, cpuNs: UInt64 = 0, start: UInt64? = nil) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: ppid, uid: uid, name: name, path: path,
                  startTime: start ?? UInt64(pid) * 1000, footprint: mb << 20,
                  cpuTimeNs: cpuNs, responsiblePid: resp ?? pid)
}

@Suite("App grouping")
struct AppGrouperTests {
    let firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
    let content = "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
    let claudeCLI = "/Users/bryan/Library/Application Support/Claude/claude-code/2.1.299/4fa9694b7975/claude.app/Contents/MacOS/claude"

    @Test func groupsHelpersUnderResponsibleApp() {
        let snap = ProcessSnapshot(timestamp: Date(), records: [
            rec(100, name: "firefox", path: firefox, mb: 900),
            rec(101, ppid: 100, name: "plugin-container", path: content, mb: 2200, resp: 100),
            rec(102, ppid: 100, name: "plugin-container", path: content, mb: 600, resp: 100),
            rec(103, ppid: 100, name: "Firefox GPU Helper", path: content, mb: 5300, resp: 100),
            rec(200, name: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", mb: 97),
        ])
        let groups = AppGrouper.group(snap)
        #expect(groups.count == 2)
        let ff = groups[0]
        #expect(ff.id == 100)
        #expect(ff.name == "Firefox")
        #expect(ff.processCount == 4)
        #expect(ff.footprint == UInt64(900 + 2200 + 600 + 5300) << 20)
        #expect(ff.kind == .app)
        #expect(groups[1].name == "Finder")
    }

    @Test func claudeCodeSessionIsAnAgentGroup() {
        let snap = ProcessSnapshot(timestamp: Date(), records: [
            rec(58413, ppid: 58412, name: "claude", path: claudeCLI, mb: 431),
            rec(95814, ppid: 95812, name: "Blender", path: "/Applications/Blender.app/Contents/MacOS/Blender", mb: 1748, resp: 58413),
            rec(95834, ppid: 95827, name: "ffmpeg", path: "/opt/homebrew/bin/ffmpeg", mb: 1603, resp: 58413),
        ])
        let groups = AppGrouper.group(snap)
        #expect(groups.count == 1)
        #expect(groups[0].kind == .agentSession)
        #expect(groups[0].name == "Claude Code")
        #expect(groups[0].footprint == UInt64(431 + 1748 + 1603) << 20)
    }

    @Test func missingResponsibleHeadUsesLargestMember() {
        // The responsible process is unreadable (root) or gone: members still group together.
        let snap = ProcessSnapshot(timestamp: Date(), records: [
            rec(301, name: "helperA", mb: 50, resp: 300),
            rec(302, name: "helperB", mb: 80, resp: 300),
        ])
        let groups = AppGrouper.group(snap)
        #expect(groups.count == 1)
        #expect(groups[0].id == 300)
        #expect(groups[0].name == "helperB")
    }

    @Test func outermostBundleNamesTheApp() {
        #expect(AppGrouper.outermostBundlePath(content) == "/Applications/Firefox.app")
        #expect(AppGrouper.outermostBundlePath("/usr/bin/python3") == nil)
        #expect(AppGrouper.bundleDisplayName(bundlePath: "/Applications/Nonexistent Thing.app") == "Nonexistent Thing")
    }

    @Test func systemProcessesAreSystemKind() {
        let snap = ProcessSnapshot(timestamp: Date(), records: [
            rec(400, uid: 0, name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores", mb: 300),
        ])
        #expect(AppGrouper.group(snap)[0].kind == .system)
    }
}

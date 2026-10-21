import Foundation
import Testing
@testable import RAMKit

/// What an upgrading user needs to be told: an older root helper, and a Firefox pref that waits
/// for the next Firefox launch.
@Suite("Upgrades and pending settings")
struct UpgradeTests {
    @Test func olderHelperIsFlaggedForUpdate() {
        #expect(ReliefAvailability.helper(version: "1.0.0").helperOutdated)
        #expect(!ReliefAvailability.helper(version: HelperConstants.version).helperOutdated)
        #expect(!ReliefAvailability.root.helperOutdated)
        #expect(ReliefAvailability.helper(version: "1.0.0").helperVersion == "1.0.0")
        let d = Diagnosis.make(system: fakeSystem(), wall: nil, snapshot: ProcessSnapshot(timestamp: Date(), records: []),
                               sessions: [], leftovers: [], reliefAvailable: true, firefoxProfile: nil, helperVersion: "1.0.0")
        #expect(d.fixes.contains { $0.title.hasPrefix("Update the root helper (installed 1.0.0") })
        let current = Diagnosis.make(system: fakeSystem(), wall: nil, snapshot: ProcessSnapshot(timestamp: Date(), records: []),
                                     sessions: [], leftovers: [], reliefAvailable: true, firefoxProfile: nil,
                                     helperVersion: HelperConstants.version)
        #expect(!current.fixes.contains { $0.title.hasPrefix("Update the root helper") })
    }

    @Test func firefoxPrefWaitsForTheNextLaunch() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("ff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let userJS = profile.appendingPathComponent("user.js")
        try FirefoxLevers.enableUnloader(profile: profile)
        let written = Date(timeIntervalSince1970: 1_792_500_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: userJS.path)
        func snapshot(startedAt: Date) -> ProcessSnapshot {
            ProcessSnapshot(timestamp: Date(), records: [
                rec(500, name: "firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox", mb: 900,
                    start: UInt64(startedAt.timeIntervalSince1970 * 1_000_000)),
                rec(501, ppid: 500, name: "plugin-container",
                    path: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container", mb: 300,
                    resp: 500, start: UInt64(written.timeIntervalSince1970 * 1_000_000) + 10),
            ])
        }
        // Started four days before the pref was written: not active yet.
        #expect(FirefoxLevers.unloaderNeedsRestart(profile: profile, snapshot: snapshot(startedAt: written.addingTimeInterval(-4 * 86_400))))
        // Started after: active.
        #expect(!FirefoxLevers.unloaderNeedsRestart(profile: profile, snapshot: snapshot(startedAt: written.addingTimeInterval(60))))
        // Not running, or the pref is off: nothing pending.
        #expect(!FirefoxLevers.unloaderNeedsRestart(profile: profile, snapshot: ProcessSnapshot(timestamp: Date(), records: [])))
        try FirefoxLevers.disableUnloader(profile: profile)
        #expect(!FirefoxLevers.unloaderNeedsRestart(profile: profile, snapshot: snapshot(startedAt: written.addingTimeInterval(-86_400))))
    }

    @Test func receiptsDirectoryCanBeRedirected() {
        // The live suite sets RAM_RECEIPTS_DIR for the CLI it runs; without it receipts live in Application Support.
        if ProcessInfo.processInfo.environment["RAM_RECEIPTS_DIR"] == nil {
            #expect(Receipt.defaultDirectory.path.hasSuffix("Library/Application Support/DownloadMoreRAM/receipts"))
        }
        setenv("RAM_RECEIPTS_DIR", "/tmp/ram-receipts-test", 1)
        defer { unsetenv("RAM_RECEIPTS_DIR") }
        #expect(Receipt.defaultDirectory.path == "/tmp/ram-receipts-test")
    }

    @Test func parsesItsOwnByteStrings() {
        #expect(Format.parseBytes("2.50 GB") == UInt64(2.5 * 1_073_741_824))
        #expect(Format.parseBytes("926.8 MB") == UInt64((926.8 * 1_048_576).rounded()))
        #expect(Format.parseBytes("+512 KB") == 524_288)
        #expect(Format.parseBytes("88 B") == 88)
        #expect(Format.parseBytes("lots") == nil)
        #expect(Format.parseBytes("2.50 TB") == nil)
        let bytes: UInt64 = 2_684_354_560
        #expect(Format.parseBytes(Format.bytes(bytes)) == bytes)
    }
}

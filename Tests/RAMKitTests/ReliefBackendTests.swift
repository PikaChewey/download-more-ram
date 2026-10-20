import Darwin
import Foundation
import Testing
@testable import RAMKit

@Suite("Relief backends (unprivileged)")
struct ReliefBackendTests {
    @Test(.enabled(if: geteuid() != 0)) func directBackendRefusesWithoutRoot() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("ram-marker-\(UUID().uuidString)").path
        await #expect(throws: ReliefError.notPermitted) {
            try await DirectSysctlBackend(marker: marker).relieve(level: .critical, holdMs: 1000)
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test(.enabled(if: geteuid() != 0 && !FileManager.default.fileExists(atPath: HelperConstants.plistPath)))
    func detectExplainsHowToEnable() async {
        let a = await ReliefAvailability.detect()
        guard case .unavailable(let reason) = a else { Issue.record("expected unavailable, got \(a)"); return }
        #expect(reason.contains("sudo ram helper install"))
        #expect(a.backend() == nil)
    }

    @Test func unreachableHelperFailsFast() async {
        let start = Date()
        let backend = HelperBackend(machService: "ca.bryanyao.DownloadMoreRAM.nonexistent.\(UUID().uuidString)")
        do {
            _ = try await backend.status(timeout: 3)
            Issue.record("expected failure")
        } catch let e as ReliefError {
            guard case .helperUnreachable = e else { Issue.record("wrong error \(e)"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func errorMessagesTellTheUserWhatToDo() {
        #expect(ReliefError.notPermitted.description == "Downloads need the helper: run  sudo ram helper install  (or sudo ram download)")
        #expect(ReliefError.restoreFailed(1).description.contains("sudo ram restore"))
    }
}

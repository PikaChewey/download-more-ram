import Foundation
import Testing
@testable import RAMKit

@Suite("Relief progress replay")
struct ReliefProgressTests {
    /// The app's clip renderer rebuilds progress from a recording, so the memberwise init is public
    /// and the CLI line renders a replayed lever beat the same way as a live one.
    @Test func replayedProgressRendersLikeLive() {
        let gpu = LeverResult(kind: .firefoxGPU, title: LeverKind.firefoxGPU.title, bytes: 971_802_208, targets: ["Firefox"],
                              detail: "GPU process 2.50 GB → 1.48 GB", durationS: 6.2)
        let signal = LeverResult(kind: .kernelSignal, title: LeverKind.kernelSignal.title, bytes: -5_898_624, targets: [],
                                 detail: nil, durationS: 15)
        let replayed = ReliefProgress(phase: .settling, elapsed: 17, total: 24, reclaimedSoFar: -5_898_624, rateBytesPerSec: 0,
                                      topApps: [], lever: .leftovers, leversDone: [signal, gpu])
        #expect(replayed.lever == .leftovers)
        #expect(replayed.leversDone.count == 2)
        let plain = ReliefProgress(phase: .holding, elapsed: 5, total: 17, reclaimedSoFar: 33_898_160, rateBytesPerSec: 4_144_107, topApps: [])
        #expect(plain.lever == nil && plain.leversDone.isEmpty)

        let style = Render.Style(color: false)
        let line = Render.progress(replayed, style: style)
        #expect(line.contains("Quit servers agents left behind…"))
        #expect(line.contains("921.2 MB"))          // signal + GPU so far, in binary units
        #expect(line.contains("7s left"))
        #expect(Render.progress(plain, style: style).contains("32.3 MB"))
    }
}

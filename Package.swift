// swift-tools-version: 6.0
//
// Download More RAM: makes apps give memory back by asking the macOS kernel for its own
// memory-pressure response, then measures exactly how much came back.
// RAMKit is the engine (no AppKit), `ram` is the CLI, `ram-helper` the root launchd daemon,
// DownloadMoreRAM the menu bar app, `ram-fixture` the controlled test processes.
// Heavy jobs go through scripts/with-build-lock.sh (one Swift build at a time on a 16 GB Mac).
//
import PackageDescription

let package = Package(
    name: "DownloadMoreRAM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RAMKit", targets: ["RAMKit"]),
    ],
    targets: [
        // C shims over libproc, sysctl, host_statistics64 and the responsibility SPI.
        // Private structs are size-checked at runtime; callers fall back on mismatch.
        .target(
            name: "CDarwinMem",
            path: "Sources/CDarwinMem"
        ),
        // The engine: samplers, grouping, wall model, relief + measurement, receipts.
        .target(
            name: "RAMKit",
            dependencies: ["CDarwinMem"],
            path: "Sources/RAMKit"
        ),
        .testTarget(
            name: "RAMKitTests",
            dependencies: ["RAMKit", "CDarwinMem"],
            path: "Tests/RAMKitTests"
        ),
    ]
)

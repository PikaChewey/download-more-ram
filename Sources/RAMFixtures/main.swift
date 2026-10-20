// ram-fixture: controlled processes for integration tests and benchmarks.
//
//   ram-fixture cachehog --mb N     holds an N MiB cache and frees it on memory pressure (well-behaved app)
//   ram-fixture dumbhog  --mb N     holds N MiB and ignores pressure (control)
//   ram-fixture leaker   --mb-per-s R --seconds T   grows R MiB/s for T s, then holds
//   ram-fixture orphan   --mb N     starts a detached dumbhog and exits (the child is reparented to launchd)
//   ram-fixture workload --mb N     allocates and writes N MiB as fast as it can, prints "seconds <t>", exits
//
// Every mode prints "ready <pid>" once its memory is resident, then parks in dispatchMain() until killed.
// Pages are filled with non-zero data so the compressor cannot fold them into nothing.
import Darwin
import Dispatch
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func arg(_ name: String, _ fallback: Int) -> Int {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count, let v = Int(a[i + 1]) { return v }
    return fallback
}

let chunkBytes = 16 << 20

func allocateChunk(seed: Int) -> UnsafeMutableRawPointer {
    let p = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 16384)
    var x = UInt64(truncatingIfNeeded: seed &* 2_654_435_761) | 1
    for offset in stride(from: 0, to: chunkBytes, by: 8) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17            // xorshift: incompressible-ish data
        p.storeBytes(of: x, toByteOffset: offset, as: UInt64.self)
    }
    return p
}

final class Cache: @unchecked Sendable {
    var chunks: [UnsafeMutableRawPointer] = []
    let lock = NSLock()
    func fill(mb: Int) {
        lock.withLock { for i in 0..<max(1, mb / 16) { chunks.append(allocateChunk(seed: i)) } }
    }
    func free() -> Int {
        lock.withLock {
            let n = chunks.count
            for c in chunks { c.deallocate() }
            chunks.removeAll()
            return n * 16
        }
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? ""
let cache = Cache()
var pressureSource: DispatchSourceMemoryPressure?

switch mode {
case "cachehog":
    cache.fill(mb: arg("--mb", 256))
    // On the main queue: top-level code is main-actor isolated in Swift 6, so a handler on another
    // queue would trip the runtime's isolation check (SIGTRAP) the moment pressure arrives.
    let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    src.setEventHandler {
        let freed = cache.free()
        if freed > 0 { print("freed \(freed)") }
    }
    src.resume()
    pressureSource = src
    print("ready \(getpid())")
case "dumbhog":
    cache.fill(mb: arg("--mb", 256))
    print("ready \(getpid())")
case "leaker":
    let rate = arg("--mb-per-s", 50), seconds = arg("--seconds", 10)
    print("ready \(getpid())")
    for s in 0..<seconds {
        cache.fill(mb: rate)
        print("leaked \((s + 1) * rate)")
        sleep(1)
    }
case "workload":
    let mb = arg("--mb", 1024)
    let start = DispatchTime.now().uptimeNanoseconds
    cache.fill(mb: mb)
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    print("seconds \(seconds)")
    _ = cache.free()
    exit(0)
case "orphan":
    var pid: pid_t = 0
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    let exe = CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("dumbhog"), strdup("--mb"), strdup("\(arg("--mb", 64))"), nil]
    let rc = posix_spawn(&pid, exe, nil, &attr, argv, environ)
    posix_spawnattr_destroy(&attr)
    guard rc == 0 else { print("spawn failed \(rc)"); exit(1) }
    print("child \(pid)")
    exit(0)
default:
    FileHandle.standardError.write(Data("usage: ram-fixture cachehog|dumbhog|leaker|orphan [--mb N]\n".utf8))
    exit(2)
}

// Park on the main queue so pressure events are delivered (never returns).
dispatchMain()

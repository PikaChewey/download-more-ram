import Foundation

public enum AppKind: String, Codable, Sendable {
    case app, agentSession, system, other
}

/// Processes macOS holds one app responsible for, summed like the Force Quit dialog does.
public struct AppGroup: Codable, Sendable, Identifiable, Equatable {
    /// The responsible pid.
    public var id: Int32
    public var name: String
    public var bundlePath: String?
    public var footprint: UInt64
    public var processCount: Int
    public var members: [ProcessRecord]
    public var kind: AppKind
    public var agent: AgentTool?

    public var head: ProcessRecord? { members.first { $0.pid == id } ?? members.first }
}

public enum AppGrouper {
    /// Groups by responsible pid (VERIFIED on macOS 26.5.2 to reproduce Force Quit's per-app
    /// totals within ~1%), sorted by footprint, largest first.
    public static func group(_ snapshot: ProcessSnapshot) -> [AppGroup] {
        var buckets: [Int32: [ProcessRecord]] = [:]
        for r in snapshot.records { buckets[r.responsiblePid, default: []].append(r) }
        var groups: [AppGroup] = []
        groups.reserveCapacity(buckets.count)
        for (resp, members) in buckets {
            let sorted = members.sorted { $0.footprint > $1.footprint }
            let head = members.first { $0.pid == resp } ?? sorted[0]
            groups.append(makeGroup(id: resp, head: head, members: sorted))
        }
        return groups.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
    }

    static func makeGroup(id: Int32, head: ProcessRecord, members: [ProcessRecord]) -> AppGroup {
        let bundle = head.path.flatMap(outermostBundlePath)
        let agent = AgentTool.detect(name: head.name, path: head.path)
        let kind: AppKind
        let name: String
        if let agent {
            kind = .agentSession
            name = agent.displayName
        } else if let bundle {
            kind = isSystemPath(bundle) && head.uid == 0 ? .system : .app
            name = bundleDisplayName(bundlePath: bundle)
        } else {
            kind = head.uid == 0 || isSystemPath(head.path ?? "") ? .system : .other
            name = head.name
        }
        return AppGroup(id: id, name: name, bundlePath: bundle,
                        footprint: members.reduce(0) { $0 + $1.footprint },
                        processCount: members.count, members: members, kind: kind, agent: agent)
    }

    /// `/Applications/Firefox.app/Contents/MacOS/plugin-container.app/...` -> `/Applications/Firefox.app`.
    public static func outermostBundlePath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }

    nonisolated(unsafe) private static var nameCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// CFBundleDisplayName / CFBundleName from the bundle's Info.plist, else the folder name.
    public static func bundleDisplayName(bundlePath: String) -> String {
        cacheLock.lock()
        if let cached = nameCache[bundlePath] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        var name = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        if let info = NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist") {
            if let display = info["CFBundleDisplayName"] as? String, !display.isEmpty { name = display }
            else if let bundleName = info["CFBundleName"] as? String, !bundleName.isEmpty { name = bundleName }
        }
        cacheLock.lock()
        nameCache[bundlePath] = name
        cacheLock.unlock()
        return name
    }

    static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/sbin/") || path.hasPrefix("/Library/Apple/")
    }
}

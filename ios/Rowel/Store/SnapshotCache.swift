import Foundation

/// 每个会话最近一次 follow 快照的本地副本。
///
/// 只解决一件事：进会话时先画上一次的内容，网络回来再整体替换。
/// 存的是快照的原始 JSON（不是渲染后的条目），因此不需要模型层实现 Codable，
/// 也不会把任何派生状态固化下来。上限按「单会话 512 KB / 保留 12 个 / 合计 6 MB」控制。
enum SnapshotCache {
    private static let keep = 12
    private static let maxTotal = 6 * 1024 * 1024
    private static let maxOne = 512 * 1024

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    static func save(_ snapshot: JSONValue, sessionId: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot.toAny()),
              data.count <= maxOne else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(sessionId), options: .atomic)
        prune()
    }

    static func load(sessionId: String) -> JSONValue? {
        guard let data = try? Data(contentsOf: file(sessionId)),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue(any: object)
    }

    /// 设置页的「清理会话缓存」。
    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    static var sizeInBytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private static func file(_ sessionId: String) -> URL {
        let name = sessionId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "session"
        return directory.appendingPathComponent(name)
    }

    /// 按修改时间从新到旧，保留 `keep` 个且总量不超过 `maxTotal`。
    private static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }
        let sorted = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }

        var total = 0
        for (index, entry) in sorted.enumerated() {
            total += entry.2
            if index >= keep || total > maxTotal {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }
}

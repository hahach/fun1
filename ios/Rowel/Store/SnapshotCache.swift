import Foundation

/// 每个会话最近一次 follow 快照的本地副本。
///
/// 只解决一件事：进会话时先画上一次的内容，网络回来再整体替换。
/// 存的是快照的原始 JSON（不是渲染后的条目），因此不需要模型层实现 Codable，
/// 也不会把任何派生状态固化下来。落盘前先 zlib 压一遍：快照里大段重复的字段名，
/// 压完通常只剩十分之一，所以上限按**压缩后**的体积算（单会话 1 MB / 保留 12 个 / 合计 6 MB）。
enum SnapshotCache {
    /// `save` 的结局。调用方必须按它打日志：以前超限是静默 return，
    /// 调用方照样报「已刷新为最新」，缓存就那么停在很早的一版上。
    enum SaveResult: Equatable, Sendable {
        /// 已落盘。`bytes` 是压缩后的体积，`items` 是快照里的条目条数。
        case saved(bytes: Int, items: Int)
        /// 压缩后仍然超限，没写。
        case tooLarge(bytes: Int)
        /// 序列化、压缩或写盘失败。
        case failed(String)
    }

    private static let keep = 12
    private static let maxTotal = 6 * 1024 * 1024
    /// 压缩后的单会话上限。
    private static let maxOne = 1024 * 1024

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    /// 压缩后落盘。日志由调用方按返回的结果打，这里不写。
    ///
    /// 序列化、压缩与写盘都在后台线程：快照动辄几百 KB，压一遍再落盘不该占主线程。
    /// JSONValue 是 Sendable，可以直接跨过去。
    @discardableResult
    static func save(_ snapshot: JSONValue, sessionId: String) async -> SaveResult {
        await Task.detached(priority: .utility) { saveNow(snapshot, sessionId: sessionId) }.value
    }

    /// save 的实体：读-压-写，不碰任何隔离状态，整段在后台线程上跑。
    private nonisolated static func saveNow(_ snapshot: JSONValue, sessionId: String) -> SaveResult {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot.toAny()) else {
            return .failed("快照序列化失败")
        }
        guard let packed = compress(data) else {
            return .failed("快照压缩失败")
        }
        guard packed.count <= maxOne else { return .tooLarge(bytes: packed.count) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try packed.write(to: file(sessionId), options: .atomic)
        } catch {
            return .failed(error.localizedDescription)
        }
        prune()
        return .saved(bytes: packed.count, items: itemCount(of: snapshot))
    }

    /// 读缓存。保持同步：进场首帧要先把上一次的内容画出来，
    /// 异步读意味着首帧仍是空的，缓存就失去了意义——这条取舍是有意的。
    static func load(sessionId: String) -> JSONValue? {
        guard let data = try? Data(contentsOf: file(sessionId)) else { return nil }
        // 新文件是 zlib 压缩件；解不开就按旧的未压缩 JSON 读——旧缓存文件必须还能读。
        let plain = decompress(data) ?? data
        guard let object = try? JSONSerialization.jsonObject(with: plain) else { return nil }
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

    private static func compress(_ data: Data) -> Data? {
        guard let packed = try? (data as NSData).compressed(using: .zlib) else { return nil }
        return packed as Data
    }

    private static func decompress(_ data: Data) -> Data? {
        guard let unpacked = try? (data as NSData).decompressed(using: .zlib) else { return nil }
        return unpacked as Data
    }

    /// 快照里的条目条数，只用于日志；取不到就是 0。
    /// 条目在快照的 `records` 里，老写法把同一批叫 `items`，两个都认。
    private static func itemCount(of snapshot: JSONValue) -> Int {
        snapshot["records"]?.arrayValue?.count ?? snapshot["items"]?.arrayValue?.count ?? 0
    }

    private static func file(_ sessionId: String) -> URL {
        let name = sessionId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "session"
        return directory.appendingPathComponent(name)
    }

    /// 按修改时间从新到旧，保留 `keep` 个且总量不超过 `maxTotal`。
    /// 压缩件与旧的未压缩件一视同仁：都按落盘大小与个数治理。
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

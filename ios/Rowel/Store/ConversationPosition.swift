import DshClientCore
import Foundation

/// 会话页的位置记忆：上次离开时停在哪儿。
///
/// 唯一有效的位置判据是像素偏移：`offsetY != nil && offsetY >= 0`（贴顶 0 也算有效）。
/// `topId`/`rowId`/`atBottom` 只为兼容旧记录保留，进场不拿它们做门槛。
/// 偏移是内容坐标里视口顶部的值（`contentOffset.y`），进场按它像素直落。
/// 按主机分会话：同一个 sessionId 在两台主机上是两个位置。
struct ConversationPosition: Codable, Equatable {
    /// 顶部可见行的 id：只为读旧记录保留，新写入一律为空串。
    var topId: String
    /// 顶部可见行的 id：只为兼容旧格式写入，新方案不读它。
    var rowId: String? = nil
    /// 视口顶部的像素偏移：唯一的有效位置判据。旧记录没有这一项，解出来是 nil。
    var offsetY: Double?
    /// 上次离开时是否在底部：只为兼容旧格式写入，新方案不读它。
    var atBottom: Bool
    /// 记下的时刻：只用于淘汰，不参与判定。
    var savedAt: Date

    /// 读到了一个可直接落位的像素偏移：贴顶 0 也算有效。
    var hasValidOffset: Bool {
        guard let offsetY else { return false }
        return offsetY >= 0
    }
}

/// 位置记忆的落盘：键 `dsh.pos.<hostKey>.<sessionId>`，值 JSON 编码。
enum ConversationPositionStore {
    private static let prefix = "dsh.pos."
    /// 最多留这么多条：位置是便利，不该在手机上无限长。
    static let keep = 200

    private static var defaults: UserDefaults { .standard }

    /// 主机键与草稿同一口径（`host:port`，见 `DraftStore.hostKey(for:)`）。
    static func hostKey(for endpoint: Endpoint) -> String {
        DraftStore.hostKey(for: endpoint)
    }

    static func load(sessionId: String, host: String) -> ConversationPosition? {
        guard let data = defaults.data(forKey: key(sessionId, host)) else { return nil }
        return try? JSONDecoder().decode(ConversationPosition.self, from: data)
    }

    static func save(_ position: ConversationPosition, sessionId: String, host: String) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: key(sessionId, host))
        prune()
    }

    private static func key(_ sessionId: String, _ host: String) -> String {
        prefix + host + "." + sessionId
    }

    /// 按 `savedAt` 淘汰到 `keep` 条：读不出来的按最旧算，先删。
    private static func prune() {
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        guard keys.count > keep else { return }
        let stamps = keys.map { key -> (String, Date) in
            let savedAt = defaults.data(forKey: key)
                .flatMap { try? JSONDecoder().decode(ConversationPosition.self, from: $0) }?
                .savedAt ?? .distantPast
            return (key, savedAt)
        }
        for (old, _) in stamps.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) {
            defaults.removeObject(forKey: old)
        }
    }
}

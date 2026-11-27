import DshClientCore
import Foundation

/// 每会话的同步记账（v2）：文本之外还留 base 与已同步文本。
///
/// 决策机进会话时会把 base／syncedText／conflict 全部重置，重新「先读后写」（契约 §13.2-1），
/// 所以这几个字段只作缓存与排障用，不参与任何判定——真正决定同步的是 `DraftSyncCore`。
struct DraftRecord: Codable, Equatable {
    var text: String
    var base: Int?
    var syncedText: String?
    var conflictText: String?
    var conflictUpdatedAt: Int?
    var dirty: Bool
    /// 落盘时刻：`prune` 按它从新到旧淘汰。旧记录没有这个字段，解码得 nil。
    var savedAt: Date? = nil
}

/// 输入框草稿：按「主机 + 会话 id」存本地。
///
/// 桌面端的草稿在浏览器 localStorage（`dsh.conversation` 前缀，按会话加后缀），
/// 宿主不暴露，App 读不到也写不回；这里只保证 App 自己的续接——切会话、回前台、
/// 杀进程重启都不丢，发送成功即清。
///
/// v2 起键里带主机：同一个 sessionId 在两台主机上是两份草稿，串了就会把 A 机的
/// 未发内容填进 B 机的输入框。旧键 `dsh.draft.<sessionId>` 只读不写，留着做一次性
/// 迁移（`DraftSyncCore.enterSession(migrating:)`，契约 §13.2-9）。
enum DraftStore {
    /// v2 键：`dsh.draft.v2.<host:port>|<sessionId>`。
    private static let prefix = "dsh.draft.v2."
    /// 旧键前缀：只有文本，只读。
    private static let legacyPrefix = "dsh.draft."
    /// 本地上限（字符）：草稿是便利，不该在手机上无限长。
    static let limit = 20_000
    private static let keep = 50

    private static var defaults: UserDefaults { .standard }

    /// 主机键：`host:port`。端口也算——同一台机器的两个实例是两份草稿。
    static func hostKey(for endpoint: Endpoint) -> String {
        "\(endpoint.host):\(endpoint.port)"
    }

    static func record(for sessionId: String, host: String) -> DraftRecord? {
        guard let data = defaults.data(forKey: key(sessionId, host)) else { return nil }
        return try? JSONDecoder().decode(DraftRecord.self, from: data)
    }

    static func save(_ record: DraftRecord, for sessionId: String, host: String) {
        var clipped = record
        clipped.text = String(record.text.prefix(limit))
        // 空文本且无冲突＝没有草稿：不占键，与 build 70 的 `clear` 同义。
        // 只删 v2 记录、不碰旧键：旧键此刻可能还没被迁移流程取走。
        guard !clipped.text.isEmpty || record.conflictText != nil else {
            removeRecord(for: sessionId, host: host)
            return
        }
        clipped.savedAt = Date()
        guard let data = try? JSONEncoder().encode(clipped) else { return }
        defaults.set(data, forKey: key(sessionId, host))
        prune(keeping: key(sessionId, host))
    }

    /// 纯本地写入（开关关闭时的唯一写法）：只动文本，其余记账保持原样。
    static func saveText(_ text: String, for sessionId: String, host: String) {
        var entry = record(for: sessionId, host: host)
            ?? DraftRecord(text: "", base: nil, syncedText: nil,
                           conflictText: nil, conflictUpdatedAt: nil, dirty: true)
        entry.text = text
        entry.dirty = true
        save(entry, for: sessionId, host: host)
    }

    /// 本机文本：v2 记录优先，没有就退回旧键（升级后第一次进来还得看得见旧草稿）。
    static func text(for sessionId: String, host: String) -> String {
        if let cached = record(for: sessionId, host: host) { return cached.text }
        return legacyText(for: sessionId) ?? ""
    }

    /// 清空草稿：v2 记录与旧键一起删——留着旧键，清掉的内容下次进来会复活。
    static func remove(for sessionId: String, host: String) {
        removeRecord(for: sessionId, host: host)
        forgetLegacy(for: sessionId)
    }

    /// 旧键的文本（一次性迁移用）。
    static func legacyText(for sessionId: String) -> String? {
        defaults.string(forKey: legacyPrefix + sessionId)
    }

    /// 旧键取用之后即删：它只服务一次性迁移，留着会在清空之后复活。
    static func forgetLegacy(for sessionId: String) {
        defaults.removeObject(forKey: legacyPrefix + sessionId)
    }

    private static func removeRecord(for sessionId: String, host: String) {
        defaults.removeObject(forKey: key(sessionId, host))
    }

    private static func key(_ sessionId: String, _ host: String) -> String {
        prefix + host + "|" + sessionId
    }

    /// 最多留 `keep` 条（新旧键一起算）：草稿是便利，不该在手机上无限长。
    ///
    /// 超限时按 `savedAt` 从新到旧留前 `keep` 条；当前键刚写过，始终在保留集合里。
    private static func prune(keeping key: String) {
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(prefix) || $0.hasPrefix(legacyPrefix)
        }
        guard keys.count > keep else { return }
        let ranked = keys.sorted { savedAt(of: $0) > savedAt(of: $1) }
        var kept = Array(ranked.prefix(keep))
        if !kept.contains(key) {
            kept.removeLast()
            kept.append(key)
        }
        for old in keys where !kept.contains(old) {
            defaults.removeObject(forKey: old)
        }
    }

    /// 记录的落盘时刻；旧键（纯文本）与解不出 `savedAt` 的记录按最旧算。
    private static func savedAt(of key: String) -> Date {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(DraftRecord.self, from: data),
              let savedAt = record.savedAt
        else { return .distantPast }
        return savedAt
    }
}

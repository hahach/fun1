import Foundation

/// 输入框草稿：按会话 id 存本地。
///
/// 桌面端的草稿在浏览器 localStorage（`dsh.conversation` 前缀，按会话加后缀），
/// 宿主不暴露，App 读不到也写不回；这里只保证 App 自己的续接——切会话、回前台、
/// 杀进程重启都不丢，发送成功即清。
enum DraftStore {
    private static let prefix = "dsh.draft."
    private static let limit = 20_000
    private static let keep = 50

    private static var defaults: UserDefaults { .standard }

    static func text(for sessionId: String) -> String {
        defaults.string(forKey: prefix + sessionId) ?? ""
    }

    static func save(_ text: String, for sessionId: String) {
        let key = prefix + sessionId
        let clipped = String(text.prefix(limit))
        if clipped.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(clipped, forKey: key)
        }
        prune(keeping: clipped.isEmpty ? nil : key)
    }

    static func clear(for sessionId: String) {
        defaults.removeObject(forKey: prefix + sessionId)
    }

    /// 最多留 `keep` 条：草稿是便利，不该在手机上无限长。
    private static func prune(keeping key: String?) {
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        guard keys.count > keep else { return }
        for old in keys where old != key {
            defaults.removeObject(forKey: old)
        }
    }
}

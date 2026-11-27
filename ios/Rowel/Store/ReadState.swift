import Foundation
import Combine

/// 哪些会话已经看过。
///
/// 判断依据只有两条：会话的 `updatedAt` 与「上次打开它的时间」。第一次用这个 App 时
/// 全部历史都会显得「未读」，所以首次启动记一个基线，早于基线的一律算已读。
@MainActor
final class ReadState: ObservableObject {
    static let shared = ReadState()

    /// 会话 id → 上次打开的时间。
    @Published private(set) var seen: [String: Date] = [:]

    private let defaults = UserDefaults.standard
    private static let seenKey = "read.seen"
    private static let baselineKey = "read.baseline"

    private init() {
        if let stored = defaults.dictionary(forKey: Self.seenKey) as? [String: Double] {
            seen = stored.mapValues { Date(timeIntervalSince1970: $0) }
        }
        if defaults.object(forKey: Self.baselineKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.baselineKey)
        }
    }

    /// 首次使用的时间点：比它更早的更新不算未读。
    private var baseline: Date {
        Date(timeIntervalSince1970: defaults.double(forKey: Self.baselineKey))
    }

    /// 只有「不在跑、说过话、且更新晚于上次查看」才算未读。
    func isUnread(_ session: SessionSummary) -> Bool {
        // 未读只对主对话：子代理会话不进主列表，标了也没人看见。
        guard !session.running, !session.blank, !session.isSubagent else { return false }
        return session.updatedAt > (seen[session.id] ?? baseline)
    }

    func markRead(_ sessionId: String, at date: Date = Date()) {
        guard (seen[sessionId] ?? .distantPast) < date else { return }
        seen[sessionId] = date
        defaults.set(seen.mapValues { $0.timeIntervalSince1970 }, forKey: Self.seenKey)
    }
}


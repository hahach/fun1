import Foundation

/// 危险动作用的验证闸门。
///
/// 上游的 `AppLock` 在启动时就要求认证；这里改成「用到能力才验」：建立连接、
/// 处置密钥、以及会话中离开超过一分钟回来。无连接时打开 App 不打扰。
@MainActor
final class SensitiveGate {
    static let shared = SensitiveGate()

    /// 会话中允许离开的最大时长，秒；设置页可改（0 表示每次回前台都验）。
    var idle: TimeInterval {
        guard let stored = UserDefaults.standard.object(forKey: "security.idleSeconds") as? Double else { return 60 }
        return stored
    }

    private let authenticator: Authenticator = DeviceAuthenticator()
    private(set) var sessionActive = false
    private var leftAt: Date?
    /// 正在弹系统认证：这期间的 scenePhase 抖动不算离开。
    private var authenticating = false
    /// 认证中的重入共享同一次认证（同一面板），不连弹、也不免验。
    private var inFlight: Task<Bool, Never>?
    /// 回前台认证被拒过：下次回前台无视 idle 阈值必须再验，通过才清除。
    private var reauthOnNextAppear = false

    /// 通过返回 true；设备不支持认证时放行，避免把主人锁在门外。
    func authenticate(reason: String) async -> Bool {
        guard authenticator.isAvailable() else { return true }
        // 系统认证面板自己会让 App 离开再回到前台；期间的重入等待首个结果，
        // 不再直接放行（并发触发的第二个敏感动作不得免验）。
        if let running = inFlight { return await running.value }
        authenticating = true
        let task = Task<Bool, Never> { [authenticator] in
            switch await authenticator.authenticate(reason: reason) {
            case .none:
                return true
            case .some(.unavailable):
                return true
            case .some(.refused):
                return false
            }
        }
        inFlight = task
        let passed = await task.value
        inFlight = nil
        authenticating = false
        if passed { reauthOnNextAppear = false }
        return passed
    }

    func sessionStarted() {
        sessionActive = true
        leftAt = nil
    }

    func sessionEnded() {
        sessionActive = false
        leftAt = nil
    }

    /// 离开前台：只在有活动会话时计时。
    func resignedActive() {
        guard sessionActive, !authenticating, leftAt == nil else { return }
        leftAt = Date()
    }

    /// 回到前台：超过阈值则要求认证。
    func becameActive() async {
        guard sessionActive, let departure = leftAt else { return }
        leftAt = nil
        // 低于 2 秒的离开是认证面板或系统提示自己造成的，不重复验。
        guard reauthOnNextAppear || Date().timeIntervalSince(departure) >= max(idle, 2) else { return }
        // 拒绝不能只当提示：记下来，下次回前台无视阈值必须再验。
        reauthOnNextAppear = !(await authenticate(reason: "会话在后台超过设定时长"))
    }
}

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
        guard authenticator.isAvailable() else {
            Diagnostics.shared.log(.info, "认证", "跳过：设备不可用，放行")
            return true
        }
        // 系统认证面板自己会让 App 离开再回到前台；期间的重入等待首个结果，
        // 不再直接放行（并发触发的第二个敏感动作不得免验）。
        if let running = inFlight {
            Diagnostics.shared.log(.info, "认证", "重入：等待进行中的验证")
            return await running.value
        }
        // 面板期间让 `AppLock` 知道这次往返不是离开（它只看得见自己的标志位）。
        // 重入走上一条 `inFlight` 分支，不计第二次：同一块面板只算一次。
        AuthActivity.begin()
        defer { AuthActivity.end() }
        authenticating = true
        Diagnostics.shared.log(.info, "认证", "开始验证：\(reason)")
        let task = Task<Bool, Never> { [authenticator] in
            switch await authenticator.authenticate(reason: reason) {
            case .none:
                Diagnostics.shared.log(.info, "认证", "验证通过")
                return true
            case .some(.unavailable):
                Diagnostics.shared.log(.info, "认证", "验证跳过：设备不可用，放行")
                return true
            case .some(.refused):
                Diagnostics.shared.log(.info, "认证", "验证取消或未通过")
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
        // 别人弹的系统面板不算离开（`AppLock` 解锁时也会让场景 inactive）。
        guard sessionActive else { return }
        if authenticating || AuthActivity.isActive {
            Diagnostics.shared.log(.info, "认证", "离开前台：认证面板往返，不计时")
            return
        }
        guard leftAt == nil else { return }
        leftAt = Date()
        Diagnostics.shared.log(.info, "认证", "离开前台：开始计时")
    }

    /// 回到前台：超过阈值则要求认证。
    ///
    /// - Parameter lockEnabled: 锁开启时「回前台验证」由锁屏独占：这里只清计时，
    ///   不再按 idle 阈值弹第二次面板。
    func becameActive(lockEnabled: Bool = false) async {
        // 这次回前台是系统面板关闭造成的：既不是离开，也不是「回来了」，
        // 清掉可能遗留的离开时点即可。
        if AuthActivity.isActive {
            leftAt = nil
            Diagnostics.shared.log(.info, "认证", "回前台：认证面板往返，跳过")
            return
        }
        if lockEnabled {
            leftAt = nil
            Diagnostics.shared.log(.info, "认证", "回前台：锁屏负责验证，跳过")
            return
        }
        guard sessionActive, let departure = leftAt else { return }
        leftAt = nil
        let away = Date().timeIntervalSince(departure)
        // 低于 2 秒的离开是认证面板或系统提示自己造成的，不重复验。
        guard reauthOnNextAppear || away >= max(idle, 2) else {
            Diagnostics.shared.log(.info, "认证", "回前台：离开 \(Int(away)) 秒未超时，跳过")
            return
        }
        Diagnostics.shared.log(.info, "认证", "回前台：离开 \(Int(away)) 秒，验证")
        // 拒绝不能只当提示：记下来，下次回前台无视阈值必须再验。
        reauthOnNextAppear = !(await authenticate(reason: "会话在后台超过设定时长"))
    }
}

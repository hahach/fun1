/// 两个闸门共用的系统认证面板计数。
///
/// 系统认证面板（面容／密码）弹出期间，App 会走一次 inactive → active。
/// `AppLock` 有自己的 `authenticating`，`SensitiveGate` 也有自己的，两者互不
/// 知情：一方弹面板，另一方看到的只是「用户离开了」，于是刚验完立刻上锁、
/// 或回前台再弹一次。这里只记「面板是否正在显示」，两个闸门各自 begin/end
/// 成对调用，判断这块面板是不是别人弹的。
@MainActor
enum AuthActivity {
    /// 正在显示的面板数。面板之间可以嵌套（一个闸门的回调里触发另一个闸门），
    /// 所以是计数而不是布尔。
    private static var depth = 0

    /// 是否有系统认证面板正在显示。
    static var isActive: Bool { depth > 0 }

    /// 弹面板前调用，与 `end()` 成对。
    static func begin() { depth += 1 }

    /// 面板结束后调用。多减出的部分按 0 处理，避免一次漏配把所有判断永久翻转。
    static func end() { depth = max(0, depth - 1) }
}

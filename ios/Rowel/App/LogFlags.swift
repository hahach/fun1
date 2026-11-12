/// 细节日志的编译期分类开关。
///
/// 三条约定：
///
/// ① 细节日志一律写成 `if DshLog.scroll { Diagnostics.shared.log(.info, "滚动", "…") }`：
///    开关是 `static let`，关闭时编译器把整段连同字符串插值一起消掉。
/// ② 开关只许包日志调用，不许包业务逻辑。
/// ③ 除排查包外，导出前必须全部为 false：`node scripts/ios-app/log-flags.mjs` 查与改，
///    `scripts/ios-app/export-public.mjs` 在导出前只读检查。
enum DshLog {
    /// 滚动与翻页。
    static let scroll = false

    /// 跟随流与重连。
    static let follow = false

    /// 发送与队列。
    static let send = false

    /// 审批与提问。
    static let interrupts = false

    /// 附件与预览。
    static let attach = false

    /// 终端。
    static let terminal = false

    /// 连接与鉴权。
    static let connection = false

    /// 性能与健康。
    static let perf = false
}

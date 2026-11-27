import Foundation

/// 「SSH 已连、dsh 未就绪」的降级态。
///
/// 与 `Stage` 的分工：`Stage` 是「正在做哪一步」的进度信号，跟着一次调用走；
/// 降级态是一个**停留态**——调用已经失败返回，连接还留着，等用户开 shell 自救或点重试。
/// 故没有把它塞进 `Stage`：那会让所有 `switch stage` 的调用方（连接页）在编译期被迫改，
/// 而它们真正需要的是「现在能不能用」这一件事，由 `degraded` 表达。
public struct Degraded: Equatable, Sendable {
    /// 失败发生在哪一步。顺序即链路顺序：解析 → 转发 → 自检 → 取凭据。
    public enum Stage: String, Equatable, Sendable {
        /// 解析 dsh 目标（`dsh-web url` / journald / 日志文件里的启动 URL）。
        case resolve
        /// 起本地端口转发。
        case forward
        /// 隧道自检（本地端口 HEAD）。
        case probe
        /// 取 token 换 cookie。
        case authenticate
    }

    public let stage: Stage
    /// 给人和日志看的原因（已折成中文，可直接上屏）。
    public let reason: String
    /// 失败是否属于「隧道这一层不通」（而非 token/cookie 不对）。
    /// 首连时只有这类失败值得整栈重建一次：重建治不了过期 token。
    public let isTunnelProblem: Bool

    public init(stage: Stage, reason: String, isTunnelProblem: Bool = false) {
        self.stage = stage
        self.reason = reason
        self.isTunnelProblem = isTunnelProblem
    }

    /// 阶段的中文名，用于日志「复用 SSH 重试 dsh：<阶段>」。
    public var stageLabel: String { DshFailureRules.stageLabel(stage) }

    /// 「SSH 已连、dsh 未就绪：<原因>」——连接页要显示的就是这一句。
    public var message: String { "SSH 已连、dsh 未就绪：\(reason)" }
}

/// 会话层可区分的失败：调用方据此决定「留连接自救」还是「整栈重建」。
public enum DshSessionError: Error, Equatable, LocalizedError {
    /// SSH 通、dsh 不通。连接仍在实例上：可 `openShell()` 自救，也可 `retryDsh()` 重试。
    case dshNotReady(Degraded)
    /// SSH 这一层已经不可用（没连过、已 `close()`、旧连接上开 channel 得
    /// `creatingChannelAfterClosure` 一类）：复用连接没有意义，整栈重建。
    case sshUnavailable(reason: String)
    /// 从未连上或已经 `close()`。
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .dshNotReady(let degraded):
            return degraded.message
        case .sshUnavailable(let reason):
            return "SSH 连接不可用：\(reason)"
        case .notConnected:
            return "SSH 尚未连接"
        }
    }

    /// 降级态本体（非降级错误为 nil）。
    public var degraded: Degraded? {
        if case .dshNotReady(let value) = self { return value }
        return nil
    }

    /// 上层该做什么。
    public var recovery: Recovery {
        switch self {
        case .dshNotReady:
            return .retryDsh
        case .sshUnavailable:
            return .rebuildStack
        case .notConnected:
            return .connect
        }
    }
}

/// 会话层失败的处置归类：Core 对上层唯一要交代的判定。
public enum Recovery: Equatable, Sendable {
    /// 复用同一条 SSH 重试 dsh（`retryDsh()`）；期间可 `openShell()` 自救。
    case retryDsh
    /// SSH 这一层已不可用：整栈重建（`restart()`）。
    case rebuildStack
    /// 还没有可用连接：先连（`open` / `restart`）。
    case connect
}

/// 判定与文案：全是纯函数，离线可测（`DshDegradationTests`）。
enum DshFailureRules {
    /// 阶段的中文名。
    static func stageLabel(_ stage: Degraded.Stage) -> String {
        switch stage {
        case .resolve: return "解析 dsh 目标"
        case .forward: return "起本地转发"
        case .probe: return "隧道自检"
        case .authenticate: return "取 dsh 凭据"
        }
    }

    /// 阶段 + 错误 → 降级态。阶段由**失败时正在做的那一步**决定，不由错误类型反推：
    /// 「转发起不来」和「自检不过」抛的错误类型可能一样，阶段不同处置也不同。
    static func degraded(stage: Degraded.Stage, error: Error) -> Degraded {
        Degraded(
            stage: stage,
            reason: reason(for: error),
            isTunnelProblem: (error as? BootstrapError)?.isTunnelProblem == true
        )
    }

    /// 原因串：优先 `LocalizedError` 的中文描述（dsh 侧错误都有），否则退到 `String(describing:)`。
    static func reason(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        let text = String(describing: error)
        return text.isEmpty ? "未知错误" : text
    }

    /// 「SSH 这一层已死」的识别：只有这类错误才值得整栈重建。
    ///
    /// 错误文本匹配是无奈之举——Citadel/NIO 把「通道已关」拆成好几种类型与包装，
    /// 而 `creatingChannelAfterClosure` 是「在已关闭的连接上开 channel」最确定的信号。
    static func sshUnavailableReason(_ error: Error) -> String? {
        if let sessionError = error as? DshSessionError {
            switch sessionError {
            case .notConnected: return "SSH 尚未连接"
            case .sshUnavailable(let reason): return reason
            case .dshNotReady: return nil
            }
        }
        if let connectionError = error as? SSHClientConnection.ConnectionError {
            switch connectionError {
            case .notConnected:
                return "SSH 尚未连接"
            default:
                // 连接阶段就失败（网络不通/被拒/主机密钥变更）不属于「连上之后死了」。
                return nil
            }
        }
        // dsh 侧的失败由阶段归类，不在这里判 SSH 死。
        if error is BootstrapError { return nil }

        let text = String(describing: error)
        let lowered = text.lowercased()
        for marker in closureMarkers where lowered.contains(marker) {
            return "SSH 通道已关闭：\(excerpt(text))"
        }
        return nil
    }

    /// 开 shell 日志里的 SSH 状态。
    static func sshState(connected: Bool, degraded: Degraded?) -> String {
        guard connected else { return "未连接" }
        return degraded == nil ? "已连" : "已连/dsh 未就绪"
    }

    /// 「通道已关」的文本标记，全小写比对。
    private static let closureMarkers = [
        "creatingchannelafterclosure",
        "creating channel after closure",
        "ioonclosedchannel",
        "channelclosed",
        "channel closed",
        "closedchannel",
        "connection closed",
        "socketclosed",
        "already closed",
    ]

    /// 错误描述可能很长（NIO 会把包装链一起打出来），日志里截一段就够定位。
    private static func excerpt(_ text: String, limit: Int = 160) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

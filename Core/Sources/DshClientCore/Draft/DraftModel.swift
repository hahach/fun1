import Foundation

/// 服务端草稿快照：`draft/get`、`draft/set` 的响应体（契约 §10.1）。
///
/// `updatedAt` 由服务端产生，是本契约唯一的版本号；客户端不自造时间戳（§11.1）。
/// `text` 为空时分两种（契约 §10.1）：`updatedAt == 0`＝从没有草稿；`updatedAt > 0`＝墓碑行的清空时刻（远端被清空过）。
public struct DraftSnapshot: Equatable, Codable, Sendable {
    /// 草稿全文；空串表示本快照没有草稿内容（从没有草稿或被清空过，靠 `updatedAt` 区分）。
    public var text: String
    /// 服务端毫秒时间戳；0 表示该键从来没有草稿行。
    public var updatedAt: Int

    public init(text: String, updatedAt: Int) {
        self.text = text
        self.updatedAt = updatedAt
    }

    /// 无草稿（`text: ""`、`updatedAt: 0`）。
    public static let empty = DraftSnapshot(text: "", updatedAt: 0)

    public var hasDraft: Bool { !text.isEmpty }
}

/// 上行失败的三类结果（契约 §11.1 的错误码 ＋ §13.2-11 的能力降级）。
///
/// 网络类失败（含 8 s 超时）不走本枚举，由调用方以 `writeTimedOut()` 事件送入决策机。
public enum DraftError: Error, Equatable, Sendable {
    /// 条件写被拒（`draft/conflict`），带回服务端当前合并视图。
    case conflict(remote: DraftSnapshot)
    /// 服务端超限（`draft/too-large`）；`bytes` 为本端待写文本的 UTF-8 字节数。
    case tooLarge(bytes: Int)
    /// `draft/*` 不可用（404／未注册）：该主机转纯本地（§13.2-11）。
    case unsupported
}

/// 同步能力模式。能力降级后整场为 `localOnly`，不再产生任何 `draft/*` 动作。
public enum DraftMode: String, Equatable, Codable, Sendable {
    /// 服务端可用：进会话先读、去抖上行、冲突挂起。
    case remote
    /// 纯本地：只留本机文本，不上行、不报错（§13.2-11）。
    case localOnly
}

/// 决策机对外可见的全部状态，供调用方渲染本地缓存、脏标记与冲突提示条。
///
/// 纯数据，不含任何编辑器对象；`isDirty` 由 `localText` 与 `syncedText` 派生，
/// 因此"上行上限跳过""写失败""读到之前就打了字"都会自然表现为脏。
public struct DraftViewState: Equatable, Sendable {
    /// 当前能力模式。
    public var mode: DraftMode
    /// 会话是否为空白会话（blank 才随读写带 `cwd`，§9.2-1）。
    public var isBlank: Bool
    /// 会话工作目录；`isBlank` 为真时作为 `cwd` 随 `draft/get`／`draft/set` 上行。
    public var cwd: String?
    /// 本机输入框当前文本。
    public var localText: String
    /// 最近一次成功 `get`／`set` 响应的 `updatedAt`；nil＝尚未读到服务端状态（先读后写未放开）。
    public var base: Int?
    /// 与应用服务端已对齐的本机文本；nil＝尚未对齐过任何文本。
    public var syncedText: String?
    /// 最近一次读到的远端快照（含 `draft/set` 的响应用来做合并视图）。
    public var remote: DraftSnapshot?
    /// 冲突态远端快照；非 nil 即输入区上方应显示冲突提示条（§13.3）。
    public var conflict: DraftSnapshot?
    /// 挂起：该会话暂不上行任何写（冲突未处置、或冲突后读失败，§13.2-7／§13.2-6⑤）。
    public var isSuspended: Bool
    /// 输入有待去抖的变化（调用方按 400 ms 后送 `debounceElapsed()`）。
    public var isDebouncing: Bool
    /// 有 `draft/set` 在飞（或等重试）：期间不再入队新写（每会话一条写队列，§13.2-4）。
    public var isPending: Bool
    /// 本会话是否已为该 `cwd` 写过工作区行（清空时据此决定是否带 `cwd`，§10.2-2）。
    public var wroteWorkspaceRow: Bool

    /// 本地相对服务端有未落地的差异（仅 remote 模式有意义）。
    public var isDirty: Bool {
        mode == .remote && localText != (syncedText ?? "")
    }

    public init(
        mode: DraftMode,
        isBlank: Bool,
        cwd: String?,
        localText: String = "",
        base: Int? = nil,
        syncedText: String? = nil,
        remote: DraftSnapshot? = nil,
        conflict: DraftSnapshot? = nil,
        isSuspended: Bool = false,
        isDebouncing: Bool = false,
        isPending: Bool = false,
        wroteWorkspaceRow: Bool = false
    ) {
        self.mode = mode
        self.isBlank = isBlank
        self.cwd = cwd
        self.localText = localText
        self.base = base
        self.syncedText = syncedText
        self.remote = remote
        self.conflict = conflict
        self.isSuspended = isSuspended
        self.isDebouncing = isDebouncing
        self.isPending = isPending
        self.wroteWorkspaceRow = wroteWorkspaceRow
    }
}

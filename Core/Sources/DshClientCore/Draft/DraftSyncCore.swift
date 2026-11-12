import Foundation

/// 决策机对外的动作。调用方按返回顺序逐条执行：一次网络调用、一次编辑器写入、
/// 一次定时器注册或一次提示条开关；`.none` 只表示"本次不产生任何副作用"。
public enum DraftAction: Equatable, Sendable {
    /// `draft/get`；`cwd` 仅在 blank 会话且 cwd 已知时非 nil（§9.2-1）。
    case get(cwd: String?)
    /// `draft/set`；`base` 即 `baseUpdatedAt`，nil＝不带该字段。v1.3 下只在已读到
    /// 服务端状态后才发写，故正常路径上 base 恒非 nil（§13.1-1）。
    case set(text: String, base: Int?, cwd: String?)
    /// 注册一次性重试定时器（上行失败退避，§13.2-5）；到点后再送 `retryElapsed()`。
    case scheduleRetry(after: Double)
    /// 把文本填进输入框（仅本地为空时回填，§13.2-2；或用户点"载入远端"）。
    case backfill(String)
    /// 进入冲突态并在输入区上方显示提示条（§13.3）。
    case showConflict(remote: DraftSnapshot)
    /// 解除冲突提示条（冲突已由用户处置或已自愈）。
    case clearConflict
    /// 对端已发送（远端是墓碑）而本机还有自己的草稿：问用户「清空」还是「保留」（§13.2-2）。
    case showConsumed(remote: DraftSnapshot)
    /// 收起「已发送」询问条（用户已选，或本机继续输入即视为保留）。
    case clearConsumed
    /// 文本超过上行上限：本次不上行，本地保留并提示（§13.2-10）。
    case tooLarge(bytes: Int)
    /// `draft/*` 不可用：该主机转纯本地，不报错（§13.2-11）。
    case degrade
    /// 本次调用不产生任何副作用（含"这次不写"的判定）。
    case none
}

extension DraftAction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .get(let cwd):
            return "get(cwd: " + DraftAction.show(cwd) + ")"
        case .set(let text, let base, let cwd):
            let baseText: String = base.map { String($0) } ?? "nil"
            let body = "set(text: " + DraftAction.show(text) + " [" + String(text.utf8.count) + "B]"
            return body + ", base: " + baseText + ", cwd: " + DraftAction.show(cwd) + ")"
        case .scheduleRetry(let after):
            return "scheduleRetry(after: " + String(after) + ")"
        case .backfill(let text):
            return "backfill(" + DraftAction.show(text) + ")"
        case .showConflict(let remote):
            return "showConflict(remote: " + DraftAction.show(remote.text) + " @" + String(remote.updatedAt) + ")"
        case .clearConflict:
            return "clearConflict"
        case .showConsumed(let remote):
            return "showConsumed(remote: @" + String(remote.updatedAt) + ")"
        case .clearConsumed:
            return "clearConsumed"
        case .tooLarge(let bytes):
            return "tooLarge(bytes: " + String(bytes) + ")"
        case .degrade:
            return "degrade"
        case .none:
            return "none"
        }
    }

    private static func show(_ text: String?, limit: Int = 32) -> String {
        guard let text = text else { return "nil" }
        let clipped = text.count <= limit ? text : String(text.prefix(limit)) + "…"
        return "\"" + clipped + "\""
    }
}

/// 跨端草稿同步的纯决策机，逐条实现契约 §13.2 的十一条决策。
///
/// 不碰网络、不起 timer、不读文件：调用方把「用户输入／去抖到点／8 s 超时／服务端响应／
/// 能力探测结果」作为事件喂进来，本机只吐动作序列。这样同一份事件序列在任何平台上
/// 都推出同一份动作序列，`DraftSyncCoreTests` 与 Web 半共用一份 JSON 清单断言（§13.4）。
///
/// 记账约定（调用方需与之配合）：
/// - 读到服务端状态之前不产生任何 `.set`（§13.1-1 先读后写）；
/// - 同一时刻至多一条 `.set` 在飞：在飞期间的编辑只置 `isDebouncing`，写落地后由
///   `writeSucceeded` 自动补发（§13.2-4 每会话一条写队列）；
/// - 上行超时按失败处理，3 s／10 s 各重试一次，仍失败则标脏，等下次进会话／回前台（§13.2-5）；
/// - 读结果 `text` 为空时按 `updatedAt` 区分「从没有草稿」（0，本机有文本则补传）与
///   「远端被清空过」（> 0，墓碑行；本机无新编辑则清本机并回填空串，见 §13.2-2）。
public struct DraftSyncCore {

    // MARK: - 口径常量

    /// 输入去抖时长（§13.2-4）：调用方在最后一次 `userEdited` 之后等这么久再送 `debounceElapsed()`。
    public static let debounceInterval: Double = 0.4
    /// 单次 `draft/get`、`draft/set` 超时（§13.2-5）。
    public static let requestTimeout: Double = 8
    /// 上行失败的重试退避（§13.2-5：3 s／10 s 各一次）。
    public static let retryDelays: [Double] = [3, 10]
    /// 上行上限，按 UTF-8 字节（§13.2-10；服务端 64 KiB 兜底）。
    public static let uploadLimitBytes: Int = 60 * 1024

    /// 文本的 UTF-8 字节数（上行判据，§13.2-10）。
    public static func utf8ByteCount(of text: String) -> Int {
        text.utf8.count
    }

    // MARK: - 内部账本

    /// 本次写的来路：镜像（输入去抖）、清空、一次性迁移。
    private enum WriteKind: Equatable {
        case mirror
        case clear
        case migration
    }

    private struct PendingWrite: Equatable {
        var text: String
        var base: Int?
        var cwd: String?
        var kind: WriteKind
    }

    /// 对外可见状态（本机文本、base、已同步文本、冲突态、挂起、dirty、mode）。
    public private(set) var state: DraftViewState

    private var pending: PendingWrite?
    private var retryCount: Int = 0
    private var rebaseUsed: Bool = false
    /// 「远端已清空」的重发只用一次：同一轮里反复撞空远端就不再重发，转「真冲突」由用户处置。
    private var emptyRebaseUsed: Bool = false
    /// 等用户处置的「对端已发送」快照：非 nil 时挂起上行，只等 clear／keep 二选一。
    private var consumedRemote: DraftSnapshot?
    private var conflictReadPending: Bool = false
    private var migratingText: String?
    private var clearIntent: Bool = false
    private var readEpoch: Int = 0
    private var writeEpoch: Int = 0

    public init(mode: DraftMode, isBlank: Bool, cwd: String?) {
        self.state = DraftViewState(mode: mode, isBlank: isBlank, cwd: cwd)
    }

    // MARK: - 1 进入会话：先读后写

    /// 进入会话（§13.2-1）。`legacyText` 是本机旧草稿——一次性迁移用，见 §13.2-9。
    ///
    /// 只发 `draft/get`；拿到读结果之前本机不产生任何写（§13.1-1）。
    public mutating func enterSession(localText: String, migrating legacyText: String? = nil) -> [DraftAction] {
        state.localText = localText
        state.base = nil
        state.syncedText = nil
        state.remote = nil
        state.conflict = nil
        state.isSuspended = false
        state.isDebouncing = false
        state.isPending = false
        state.wroteWorkspaceRow = false
        pending = nil
        retryCount = 0
        rebaseUsed = false
        emptyRebaseUsed = false
        consumedRemote = nil
        conflictReadPending = false
        clearIntent = false
        migratingText = legacyText
        readEpoch = writeEpoch
        guard state.mode == .remote else {
            migratingText = nil
            return [.none]
        }
        return [.get(cwd: readCwd())]
    }

    /// 重新读一次（回前台／重新进入，§5、§13.3）。与进会话一样只发 `draft/get`；
    /// 本次读发出之后若发生过任何入队写，其结果送达时会被判为陈旧快照丢弃（§11.2-6）。
    public mutating func refresh() -> [DraftAction] {
        guard state.mode == .remote else { return [.none] }
        readEpoch = writeEpoch
        return [.get(cwd: readCwd())]
    }

    // MARK: - 2 读结果：回填／冲突／补传

    /// `draft/get` 的结果送达。
    public mutating func remoteRead(_ snapshot: DraftSnapshot) -> [DraftAction] {
        guard state.mode == .remote else { return [.none] }
        if conflictReadPending { return resolveConflictRead(snapshot) }
        if writeEpoch != readEpoch { return [.none] }   // 陈旧快照：不回填、不登记 base（§11.2-6）

        state.remote = snapshot
        state.base = snapshot.updatedAt

        // 本机为空：仅此时回填（§13.2-2），或把本机旧草稿一次性上送（§13.2-9）。
        guard !state.localText.isEmpty else {
            if !snapshot.text.isEmpty {
                state.localText = snapshot.text
                state.syncedText = snapshot.text
                state.conflict = nil
                state.isSuspended = false
                migratingText = nil
                return [.backfill(snapshot.text)]
            }
            state.syncedText = ""
            state.conflict = nil
            state.isSuspended = false
            // 远端 text 为空但 updatedAt > 0＝墓碑行：远端被清空过，本机也空即对齐，不上行（§13.2-2）。
            if snapshot.updatedAt > 0 { return [.none] }
            if let legacy = migratingText, !legacy.isEmpty {
                migratingText = nil
                return enqueueWrite(text: legacy, base: snapshot.updatedAt, cwd: writeCwd(), kind: .migration)
            }
            return [.none]
        }

        // 本机非空：输入框内容优先于旧草稿。
        migratingText = nil
        if snapshot.text == state.localText {
            state.syncedText = snapshot.text
            state.conflict = nil
            state.isSuspended = false
            return [.none]
        }
        if snapshot.text.isEmpty {
            if snapshot.updatedAt > 0 {
                // 墓碑行：别处已经把这条会话的草稿用掉了（发送）。
                if state.localText == (state.syncedText ?? "") {
                    // 本机没有新编辑：草稿已被消费，清本机并回填空串（§13.2-2）。
                    state.localText = ""
                    state.syncedText = ""
                    state.conflict = nil
                    state.isSuspended = false
                    return [.backfill("")]
                }
                // 本机另有草稿：问用户「清空／保留」，决定之前不上行（§13.2-2 折中口径）。
                consumedRemote = snapshot
                state.isSuspended = true
                state.isDebouncing = false
                return [.showConsumed(remote: snapshot)]
            }
            // 远端没有草稿行：本机文本即真相，以读到的 base 补传（离线期间的编辑在此落地，§13.1-1）。
            return enqueueWrite(text: state.localText, base: snapshot.updatedAt, cwd: writeCwd(), kind: .mirror)
        }
        // 两端都非空且不同：保留本机文本、置冲突态、不写（§13.2-3）。
        state.conflict = snapshot
        state.isSuspended = true
        state.isDebouncing = false
        return [.showConflict(remote: snapshot)]
    }

    /// `draft/get` 失败（超时或传输错误）。
    public mutating func readFailed() -> [DraftAction] {
        guard state.mode == .remote else { return [.none] }
        if conflictReadPending {
            // §13.2-6⑤：读失败保持挂起，下次进会话重试。
            conflictReadPending = false
            state.isPending = false
            state.isSuspended = true
            pending = nil
            retryCount = 0
            return [.none]
        }
        // 进会话的读失败：本机文本保留并标脏，等恢复后先读再补传（§13.1-1），不产生写。
        return [.none]
    }

    // MARK: - 3 输入与去抖

    /// 输入框内容变化（§13.2-4）。只标记待去抖，不产生动作；去抖由调用方计时。
    public mutating func userEdited(_ text: String) -> [DraftAction] {
        state.localText = text
        // 继续输入就是「保留」：询问条收起，之后的编辑照常上行（§13.2-2）。
        var head: [DraftAction] = []
        if consumedRemote != nil {
            consumedRemote = nil
            state.isSuspended = false
            head.append(.clearConsumed)
        }
        // 两侧都空＝没有可对照的内容：冲突态当场撤掉，不留一个空提示条。
        let cleared: [DraftAction] = dropEmptyConflict() ? [.clearConflict] : []
        head += cleared
        let clearedActions = head
        guard state.mode == .remote else { return clearedActions.isEmpty ? [.none] : clearedActions }
        guard !state.isSuspended, state.conflict == nil, !conflictReadPending else {
            state.isDebouncing = false
            return clearedActions.isEmpty ? [.none] : clearedActions
        }
        state.isDebouncing = true
        clearIntent = false
        return clearedActions.isEmpty ? [.none] : clearedActions
    }

    /// 去抖到点（§13.2-4）：到点才入队，连续输入只发最后一次。
    public mutating func debounceElapsed() -> [DraftAction] {
        guard state.mode == .remote else {
            state.isDebouncing = false
            return [.none]
        }
        guard !state.isSuspended, state.conflict == nil, !conflictReadPending else {
            state.isDebouncing = false
            return [.none]
        }
        guard !state.isPending else { return [.none] }   // 已有写在飞：落地时由 writeSucceeded 补发
        state.isDebouncing = false
        return flush()
    }

    /// 发送成功或输入被删光（§13.2-8）：立即入队写空串，不等去抖。
    ///
    /// 带 `cwd` 当且仅当本机曾为该 `cwd` 写过工作区行（§10.2-2 的 owner 连带删除）。
    public mutating func userCleared() -> [DraftAction] {
        state.localText = ""
        guard state.mode == .remote else {
            state.isDebouncing = false
            return [.none]
        }
        // 冲突里没有远端内容（对方已清空）：本机也清空就是对齐，冲突态先撤再走清空流程。
        var actions: [DraftAction] = []
        // 输入被清空＝这条草稿不在了：还挂着的「对端已发送」询问条到此为止（§13.2-2）。
        if consumedRemote != nil {
            consumedRemote = nil
            state.isSuspended = false
            actions.append(.clearConsumed)
        }
        if dropEmptyConflict() { actions.append(.clearConflict) }
        guard !state.isSuspended, state.conflict == nil, !conflictReadPending else {
            state.isDebouncing = false
            clearIntent = false
            return actions.isEmpty ? [.none] : actions   // 冲突态期间不上行（§13.2-7）
        }
        clearIntent = true
        state.isDebouncing = true
        guard !state.isPending else { return actions.isEmpty ? [.none] : actions }
        return actions + flush()
    }

    // MARK: - 4 写结果

    /// `draft/set` 成功（§13.2-5）：以响应里的 `updatedAt` 推进 base。
    public mutating func writeSucceeded(_ snapshot: DraftSnapshot) -> [DraftAction] {
        state.base = snapshot.updatedAt
        state.remote = snapshot
        state.isPending = false
        state.conflict = nil
        state.isSuspended = false
        retryCount = 0
        conflictReadPending = false
        if let done = pending {
            state.syncedText = done.text
            switch done.kind {
            case .mirror:
                if done.cwd != nil { state.wroteWorkspaceRow = true }
            case .clear:
                if done.cwd != nil { state.wroteWorkspaceRow = false }
            case .migration:
                break
            }
        } else {
            state.syncedText = snapshot.text
        }
        pending = nil
        return flush()
    }

    /// `draft/set` 业务失败（§13.2-6／§13.2-10／§13.2-11）。
    public mutating func writeFailed(_ error: DraftError) -> [DraftAction] {
        guard state.mode == .remote else { return [.none] }
        switch error {
        case .conflict(let remote):
            guard pending != nil else { return [.none] }
            // 先 draft/get 取远端当前值，再走五判（§13.2-6）。
            state.remote = remote
            conflictReadPending = true
            state.isPending = true
            retryCount = 0
            return [.get(cwd: pending?.cwd)]
        case .tooLarge(let bytes):
            // 不截断、不上行，本地保留并提示（§10.3-2、§13.2-10）。
            pending = nil
            state.isPending = false
            state.isDebouncing = false
            retryCount = 0
            return [.tooLarge(bytes: bytes)]
        case .unsupported:
            return degrade(to: .localOnly)
        }
    }

    /// `draft/set` 8 s 超时（按失败处理，§13.2-5）。
    ///
    /// 传输类失败（连接断开、协议错误等）也走这里：`DraftError` 只承载业务错误码。
    public mutating func writeTimedOut() -> [DraftAction] {
        guard state.mode == .remote else { return [.none] }
        guard pending != nil else {
            state.isPending = false
            return [.none]
        }
        state.isPending = false
        if retryCount < Self.retryDelays.count {
            let delay = Self.retryDelays[retryCount]
            retryCount += 1
            return [.scheduleRetry(after: delay)]
        }
        // 重试额度用完：标脏（`state.isDirty` 派生），下次进会话或回前台补传。
        pending = nil
        retryCount = 0
        state.isDebouncing = false
        return [.none]
    }

    /// 重试定时器到点：重发同一条写。
    public mutating func retryElapsed() -> [DraftAction] {
        guard state.mode == .remote else { return [.none] }
        guard !state.isSuspended, state.conflict == nil, !conflictReadPending else { return [.none] }
        guard let again = pending else { return [.none] }
        state.isPending = true
        writeEpoch += 1
        return [.set(text: again.text, base: again.base, cwd: again.cwd)]
    }

    // MARK: - 5 冲突处置

    /// 用户选「载入远端」（§13.3）：远端文本填入输入框、base 取远端 `updatedAt`、解除挂起。
    public mutating func userAskedRemote() -> [DraftAction] {
        guard let conflict = state.conflict else { return [.none] }
        state.conflict = nil
        state.isSuspended = false
        state.localText = conflict.text
        state.syncedText = conflict.text
        state.base = conflict.updatedAt
        state.remote = conflict
        state.isDebouncing = false
        pending = nil
        retryCount = 0
        rebaseUsed = false
        emptyRebaseUsed = false
        clearIntent = false
        return [.backfill(conflict.text), .clearConflict]
    }

    /// 用户选「用本机覆盖」（§13.3）：以远端 `updatedAt` 为 base 重发本机文本、解除挂起。
    public mutating func userAskedOverwrite() -> [DraftAction] {
        guard let conflict = state.conflict else { return [.none] }
        guard state.mode == .remote else { return [.none] }
        let text = state.localText
        if let bytes = Self.oversizeBytes(of: text) {
            // 超限：不写、保留冲突态与提示条，等用户缩短（§13.2-10）。
            return [.tooLarge(bytes: bytes)]
        }
        state.conflict = nil
        state.isSuspended = false
        state.base = conflict.updatedAt
        state.remote = conflict
        state.isDebouncing = false
        clearIntent = false
        retryCount = 0
        pending = nil
        let kind: WriteKind = text.isEmpty ? .clear : .mirror
        let cwd = text.isEmpty ? clearCwd() : writeCwd()
        return [.clearConflict] + enqueueWrite(text: text, base: conflict.updatedAt, cwd: cwd, kind: kind)
    }

    /// 用户选「清空」（§13.2-2）：对端已发送，本机草稿作废——清本机并回填空串，不上行。
    public mutating func userChoseClearConsumed() -> [DraftAction] {
        guard let remote = consumedRemote else { return [.none] }
        consumedRemote = nil
        state.localText = ""
        state.syncedText = ""
        state.conflict = nil
        state.isSuspended = false
        state.isDebouncing = false
        state.base = remote.updatedAt
        clearIntent = false
        pending = nil
        retryCount = 0
        return [.clearConsumed, .backfill("")]
    }

    /// 用户选「保留」（§13.2-2）：以对端清空的时刻为 base，把本机草稿上行一次。
    public mutating func userChoseKeepConsumed() -> [DraftAction] {
        guard let remote = consumedRemote else { return [.none] }
        consumedRemote = nil
        state.isSuspended = false
        state.base = remote.updatedAt
        state.conflict = nil
        clearIntent = false
        let kind: WriteKind = state.localText.isEmpty ? .clear : .mirror
        let cwd = state.localText.isEmpty ? clearCwd() : writeCwd()
        return [.clearConsumed] + enqueueWrite(text: state.localText, base: remote.updatedAt, cwd: cwd, kind: kind)
    }

    // MARK: - 6 能力与生命周期

    /// `draft/*` 不可用（404／未注册，§13.2-11）：该主机转纯本地，不报错。
    public mutating func capabilityMissing() -> [DraftAction] {
        degrade(to: .localOnly)
    }

    /// 会话从空白变为有消息（发送后）。此后镜像不再带 `cwd`（§9.2-1），
    /// 清空仍按"曾写过工作区行"带 `cwd`（§10.2-2）。
    public mutating func sessionBecameNonBlank() -> [DraftAction] {
        state.isBlank = false
        return [.none]
    }

    // MARK: - 内部

    private mutating func degrade(to mode: DraftMode) -> [DraftAction] {
        guard state.mode != mode else { return [.none] }
        state.mode = mode
        state.base = nil
        state.syncedText = nil
        state.remote = nil
        state.conflict = nil
        state.isSuspended = false
        state.isDebouncing = false
        state.isPending = false
        pending = nil
        retryCount = 0
        conflictReadPending = false
        clearIntent = false
        migratingText = nil
        consumedRemote = nil
        return [.degrade]
    }

    /// 读请求的 `cwd`：只有 blank 会话才带（§9.2-1）。
    private func readCwd() -> String? {
        guard state.isBlank, let cwd = state.cwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// 镜像写的 `cwd`：与读同口径。
    private func writeCwd() -> String? {
        readCwd()
    }

    /// 清空写的 `cwd`：仅当本机曾为该 cwd 写过工作区行（§10.2-2 owner 连带删除）。
    private func clearCwd() -> String? {
        guard state.wroteWorkspaceRow, let cwd = state.cwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    private static func oversizeBytes(of text: String) -> Int? {
        let bytes = text.utf8.count
        return bytes > uploadLimitBytes ? bytes : nil
    }

    /// 冲突的远端为空且本机也空了：没有可对照的内容，冲突态当场撤掉。
    /// - Returns: 是否真的撤掉了一个空冲突。
    private mutating func dropEmptyConflict() -> Bool {
        guard let conflict = state.conflict, conflict.text.isEmpty, state.localText.isEmpty else { return false }
        state.conflict = nil
        state.isSuspended = false
        return true
    }

    /// 记账一次"已落地"的写：镜像写记下工作区行归属，清空写注销它（§10.2-2）。
    private mutating func noteLanded(_ attempted: PendingWrite) {
        switch attempted.kind {
        case .mirror:
            if attempted.cwd != nil { state.wroteWorkspaceRow = true }
        case .clear:
            if attempted.cwd != nil { state.wroteWorkspaceRow = false }
        case .migration:
            break
        }
    }

    /// 入队一条写：判上限、记在飞、推 writeEpoch。
    private mutating func enqueueWrite(text: String, base: Int?, cwd: String?, kind: WriteKind) -> [DraftAction] {
        if let bytes = Self.oversizeBytes(of: text) {
            state.isDebouncing = false
            return [.tooLarge(bytes: bytes)]
        }
        pending = PendingWrite(text: text, base: base, cwd: cwd, kind: kind)
        state.isPending = true
        state.isDebouncing = false
        retryCount = 0
        rebaseUsed = false
        emptyRebaseUsed = false
        writeEpoch += 1
        return [.set(text: text, base: base, cwd: cwd)]
    }

    /// 队列空档里把待上行的本地差异发出去（去抖到点／写落地后的补发／立即清空）。
    private mutating func flush() -> [DraftAction] {
        guard state.mode == .remote,
              !state.isSuspended,
              state.conflict == nil,
              !conflictReadPending,
              !state.isPending else { return [.none] }
        guard let base = state.base else { return [.none] }   // 先读后写未放开（§13.1-1）
        if clearIntent && !state.localText.isEmpty { clearIntent = false }
        if clearIntent {
            clearIntent = false
            state.isDebouncing = false
            guard (state.syncedText ?? "") != "" else { return [.none] }   // 服务端已无草稿：无需删
            return enqueueWrite(text: "", base: base, cwd: clearCwd(), kind: .clear)
        }
        state.isDebouncing = false
        if state.localText == (state.syncedText ?? "") { return [.none] }
        return enqueueWrite(text: state.localText, base: base, cwd: writeCwd(), kind: .mirror)
    }

    /// 冲突后 `draft/get` 的结果：五判（§13.2-6）。
    private mutating func resolveConflictRead(_ snapshot: DraftSnapshot) -> [DraftAction] {
        conflictReadPending = false
        state.isPending = false
        state.remote = snapshot
        guard let attempted = pending else { return [.none] }
        pending = nil
        state.base = snapshot.updatedAt

        // 一次性迁移：撞冲突即跳过，远端更新，不算失败（§13.2-9）。
        if attempted.kind == .migration {
            retryCount = 0
            if state.localText.isEmpty && !snapshot.text.isEmpty {
                state.localText = snapshot.text
                state.syncedText = snapshot.text
                state.conflict = nil
                state.isSuspended = false
                return [.backfill(snapshot.text)]
            }
            return [.none]
        }

        // ① 远端为空且本端要写空串：本端的清空本就达成（§13.2-6①）。
        if snapshot.text.isEmpty && attempted.text.isEmpty {
            state.syncedText = ""
            noteLanded(attempted)
            state.conflict = nil
            state.isSuspended = false
            retryCount = 0
            return flush()
        }

        // ② 两端要写的内容相同：视为已落地（超时重发常见，§13.2-6②）。
        if snapshot.text == attempted.text {
            state.syncedText = attempted.text
            noteLanded(attempted)
            state.conflict = nil
            state.isSuspended = false
            retryCount = 0
            return flush()
        }

        // ③′ 前缀重基：远端是本端待写文本的前缀（且不完全相同），以远端 updatedAt 为重基重发一次。
        if !snapshot.text.isEmpty,
           snapshot.text != attempted.text,
           attempted.text.hasPrefix(snapshot.text),
           !rebaseUsed {
            rebaseUsed = true
            pending = PendingWrite(text: attempted.text, base: snapshot.updatedAt, cwd: attempted.cwd, kind: attempted.kind)
            state.isPending = true
            writeEpoch += 1
            return [.set(text: attempted.text, base: snapshot.updatedAt, cwd: attempted.cwd)]
        }

        // ⑤ 两端都空：远端已清空、本机也清空，没有可对照的内容（§13.2-6①的延伸）。
        //    直接对齐，不摆一个两侧都空的冲突条。
        if snapshot.text.isEmpty && state.localText.isEmpty {
            state.syncedText = ""
            state.conflict = nil
            state.isSuspended = false
            retryCount = 0
            return [.clearConflict]
        }

        // ③″ 远端为空（没有行，或墓碑＝被别的设备清空）：本机文本即真相，以远端 updatedAt 为 base 重发一次。
        //     别处发送把草稿消费掉之后，本端刚打的字不该被摆成一个「空远端冲突条」。
        //     排在 ⑤ 之后：本机此刻已经清空时，⑤ 的对齐优先（此后才轮到这条）。
        if snapshot.text.isEmpty, !attempted.text.isEmpty, !emptyRebaseUsed {
            emptyRebaseUsed = true
            pending = PendingWrite(text: attempted.text, base: snapshot.updatedAt, cwd: attempted.cwd, kind: attempted.kind)
            state.isPending = true
            writeEpoch += 1
            return [.set(text: attempted.text, base: snapshot.updatedAt, cwd: attempted.cwd)]
        }

        // ④ 真冲突：不写、不重试，挂起该会话上行并置冲突态（§13.2-6④、§13.2-7）。
        state.conflict = snapshot
        state.isSuspended = true
        state.isDebouncing = false
        retryCount = 0
        return [.showConflict(remote: snapshot)]
    }
}

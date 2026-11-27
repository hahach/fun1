import DshClientCore
import Foundation

/// 控制器只要一个 `call`：不绑整条传输栈，也让测试能塞一个假的进来对照。
protocol DraftCaller: AnyObject, Sendable {
    func call(_ endpoint: String, _ args: JSONValue) async throws -> JSONValue
}

extension DshTransport: DraftCaller {}

/// 8 秒没回来：与传输类失败同路，都送 `writeTimedOut()`／`readFailed()`。
private struct DraftRequestTimedOut: Error {}

/// 跨端草稿同步的执行层（D2）：把 `DraftSyncCore` 吐出的动作翻成 RPC、定时器与界面回调。
///
/// 判定一律在 Core（纯逻辑，两端跑同一份场景清单，契约 §13.4）；这里只管执行——
/// 网络、8 秒超时、400 ms 去抖、3 s／10 s 退避、本地缓存，以及各界面出口。
/// 一条挂死的请求不会堵住后续：请求都在独立 Task 里跑，队列由决策机的 `isPending` 管（§13.2-5）。
@MainActor
final class DraftSync {
    /// 界面出口。控制器不持视图：视图照动作改自己的 `@State`；开关关掉时整只控制器都不建。
    var onBackfill: ((String) -> Void)?
    var onConflict: ((DraftSnapshot) -> Void)?
    var onClearConflict: (() -> Void)?
    /// 对端已发送（远端成墓碑）而本机另有草稿：询问条要显示的远端快照。
    var onConsumed: ((DraftSnapshot) -> Void)?
    var onConsumedCleared: (() -> Void)?
    var onTooLarge: ((Int) -> Void)?
    /// 未同步状态：true＝有改动没上去（在重试），false＝已对齐。只按翻转上报一次。
    var onSyncState: ((Bool) -> Void)?

    private var core: DraftSyncCore
    private let caller: DraftCaller
    private let sessionId: String
    private let host: String
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// 已停：退场之后不再接受新的用户事件（在飞请求照常收尾，记账不能停在半路）。
    private var stopped = false
    /// 当前是否处于「未同步」：重试每次都报会把提示条与日志刷成噪声，所以只在翻转时动手。
    private var unsynced = false
    /// 这一轮进场读过但没读成：此时决策机没有 base，任何输入都不会发出请求，
    /// 也就不会有「写失败」可报——提示条只能由这里点出来。
    private var readFailedOnce = false
    /// 当前有没有网：没有网时不等请求超时，直接如实报「未同步」。
    private let isOnline: () -> Bool

    /// 进程内已判「该主机没有 draft/*」：再进会话直接纯本地，一条请求都不发（§13.2-11）。
    private static var degradedHosts: Set<String> = []

    var state: DraftViewState { core.state }

    init(caller: DraftCaller, sessionId: String, isBlank: Bool, cwd: String?, host: String,
         isOnline: @escaping () -> Bool = { true }) {
        self.caller = caller
        self.isOnline = isOnline
        self.sessionId = sessionId
        self.host = host
        // 本机已探过这一主机不支持：不必再探，直接纯本地（Core 此后不产生任何 draft/* 动作）。
        let mode: DraftMode = Self.degradedHosts.contains(host) ? .localOnly : .remote
        self.core = DraftSyncCore(mode: mode, isBlank: isBlank, cwd: cwd)
    }

    // MARK: - 进会话与回前台

    /// 进会话：读本地缓存（没有就读旧键）→ `enterSession` → 执行返回的动作。
    /// 返回该填进输入框的本机文本。
    @discardableResult
    func enter() -> String {
        // 没网就不要等请求超时再报警：这一刻起本机就是「未同步」。
        if !isOnline() { reportSync(true) }
        let cached = DraftStore.record(for: sessionId, host: host)
        // 有 v2 记录＝已经进过新流程；只有这时才认旧键，免得每次进会话重放一次。
        let legacy = cached == nil ? (DraftStore.legacyText(for: sessionId) ?? "") : ""
        // 旧键在 iOS 上存的就是输入框内容，所以它按「本机文本」进决策机：远端为空就补传、
        // 两边都有且不同就摆冲突条，用户立刻看得见自己的旧草稿。决策机的 `migrating` 只在
        // 输入框为空时才用得上（Web 半的旧草稿本来就不在输入框里），这里一并传进去不改行为。
        let local = cached?.text ?? legacy
        run(core.enterSession(localText: local, migrating: legacy.isEmpty ? nil : legacy))
        // 落过盘再删旧键：取用之后它就是冗余，留着会在清空草稿之后复活。
        if !legacy.isEmpty { DraftStore.forgetLegacy(for: sessionId) }
        return core.state.localText
    }

    /// 回前台／重新进入：重读一次（别的设备可能写过）。顺带把退场时停掉的控制器接回来。
    func refresh() {
        stopped = false
        run(core.refresh())
    }

    // MARK: - 用户事件

    /// 输入变化：先喂决策机，再重置 400 ms 去抖（连续输入只发最后一次，§13.2-4）。
    func userEdited(_ text: String) {
        guard !stopped else { return }
        run(core.userEdited(text), persist: false)
        debounceTask?.cancel()
        guard core.state.isDebouncing else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DraftSyncCore.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.run(self.core.debounceElapsed(), persist: false)
        }
    }

    /// 发送成功或输入被删光：立刻上行空串，不等去抖（§13.2-8）。
    func userCleared() {
        guard !stopped else { return }
        debounceTask?.cancel()
        // 输入框已经空了：那条提示跟着一起撤，不必等重试成功。
        reportSync(false)
        run(core.userCleared())
    }

    /// 会话从空白变有消息：此后镜像不再带 `cwd`（§9.2-1）。
    func sessionBecameNonBlank() {
        run(core.sessionBecameNonBlank())
    }

    /// 用户选「载入远端」（§13.3）：远端文本填进输入框、解除挂起。
    func userAskedRemote() {
        guard !stopped else { return }
        debounceTask?.cancel()
        run(core.userAskedRemote())
    }

    /// 用户选「用本机覆盖」（§13.3）：以远端 `updatedAt` 为 base 重发本机文本。
    func userAskedOverwrite() {
        guard !stopped else { return }
        debounceTask?.cancel()
        run(core.userAskedOverwrite())
    }

    /// 用户选「清空」（已发送询问条）：本机草稿作废，清空并回填空串，不上行（§13.2-2）。
    func userChoseClearConsumed() {
        guard !stopped else { return }
        debounceTask?.cancel()
        run(core.userChoseClearConsumed())
    }

    /// 用户选「保留」（已发送询问条）：以墓碑时刻为 base 上行本机草稿（§13.2-2）。
    func userChoseKeepConsumed() {
        guard !stopped else { return }
        debounceTask?.cancel()
        run(core.userChoseKeepConsumed())
    }

    // MARK: - 本地缓存与退场

    /// 本地落盘：文本以输入框为准，base／已同步／冲突取自决策机。
    func persistLocal(_ text: String) {
        let state = core.state
        DraftStore.save(
            DraftRecord(
                text: text,
                base: state.base,
                syncedText: state.syncedText,
                conflictText: state.conflict?.text,
                conflictUpdatedAt: state.conflict?.updatedAt,
                dirty: state.isDirty
            ),
            for: sessionId,
            host: host
        )
    }

    /// 退场或用户关掉开关：只停去抖计时器——那一次上行留给下次进会话补传（脏了就会补）。
    ///
    /// 在飞请求与重试不掐：掐掉等于丢掉这次写的结局，决策机的 `isPending` 会一直挂着，
    /// 该会话此后一条写都发不出去（直到重新进会话把记账清零）。
    /// 再进来时 `refresh()` 会把 `stopped` 放回去，控制器因此可以一直复用。
    func suspend() {
        stopped = true
        debounceTask?.cancel(); debounceTask = nil
    }

    // MARK: - 动作执行

    /// `persist` 只在状态推进时落盘；逐键输入那一路由视图的 400 ms 去抖负责，
    /// 否则每敲一下都写一次 UserDefaults，去抖就白做了。
    private func run(_ actions: [DraftAction], persist: Bool = true) {
        for action in actions { perform(action) }
        if persist { persistLocal(core.state.localText) }
        reportStuckIfNeeded()
    }

    /// 读没成过、本机又有内容：这条改动连请求都发不出去（先读后写没放开），
    /// 不报就永远一声不响。读成之后由既有的 reportSync(false) 收敛。
    private func reportStuckIfNeeded() {
        let state = core.state
        guard state.mode == .remote, (readFailedOnce || !isOnline()), !state.localText.isEmpty,
              !state.isPending, !state.isDebouncing else { return }
        reportSync(true)
    }

    private func perform(_ action: DraftAction) {
        switch action {
        case .get(let cwd):
            read(cwd: cwd)
        case .set(let text, let base, let cwd):
            write(text: text, base: base, cwd: cwd)
        case .scheduleRetry(let after):
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.run(self.core.retryElapsed())
            }
        case .backfill(let text):
            onBackfill?(text)
        case .showConflict(let remote):
            onConflict?(remote)
        case .clearConflict:
            onClearConflict?()
        case .showConsumed(let remote):
            onConsumed?(remote)
        case .clearConsumed:
            onConsumedCleared?()
        case .tooLarge(let bytes):
            onTooLarge?(bytes)
        case .degrade:
            degrade()
        case .none:
            break
        }
    }

    private func read(cwd: String?) {
        var args: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let cwd { args["cwd"] = .string(cwd) }
        let caller = self.caller
        Task { [weak self] in
            do {
                let reply = try await Self.call(caller, "draft/get", .object(args))
                // 在飞的结局一律收下（退场只停用户事件）：丢掉它，记账就停在半路上。
                guard let self else { return }
                guard let snapshot = Self.snapshot(reply) else {
                    // 形状不认识＝这次读没有结果：按失败处理，绝不拿空快照冒充「远端无草稿」。
                    // 原始响应截一段进日志：下次照着它就能看出是哪一层丢了字段。
                    Diagnostics.shared.log(.warn, "草稿", "draft/get 响应形状不认识：\(Self.excerpt(reply))")
                    self.reportSync(true)
                    self.run(self.core.readFailed())
                    return
                }
                self.readFailedOnce = false
                self.reportSync(false)
                self.run(self.core.remoteRead(snapshot))
            } catch {
                guard let self else { return }
                self.handleReadFailure(error)
            }
        }
    }

    private func write(text: String, base: Int?, cwd: String?) {
        var args: [String: JSONValue] = ["sessionId": .string(sessionId), "text": .string(text)]
        if let base { args["baseUpdatedAt"] = .number(Double(base)) }
        if let cwd { args["cwd"] = .string(cwd) }
        let caller = self.caller
        Task { [weak self] in
            do {
                let reply = try await Self.call(caller, "draft/set", .object(args))
                guard let self else { return }
                guard let snapshot = Self.snapshot(reply) else {
                    // 写没拿到可认的响应＝这次写没落地：按超时处理，走重试而不是假装成功。
                    Diagnostics.shared.log(.warn, "草稿", "draft/set 响应形状不认识，按失败重试：\(Self.excerpt(reply))")
                    self.reportSync(true)
                    self.run(self.core.writeTimedOut())
                    return
                }
                self.reportSync(false)
                self.run(self.core.writeSucceeded(snapshot))
            } catch {
                guard let self else { return }
                self.handleWriteFailure(error, text: text)
            }
        }
    }

    // MARK: - 失败归类

    private enum Failure {
        case conflict
        case tooLarge
        case unsupported
        case transient
    }

    /// 只有业务错误码与 404 有专门去向，其余（含 8 秒超时、连接断开）一律 transient（§13.2-5／§13.2-11）。
    private static func classify(_ error: Error) -> Failure {
        guard let rpc = error as? RPCError else { return .transient }
        switch rpc {
        case .remote(let code, _):
            switch code {
            case "draft/conflict": return .conflict
            case "draft/too-large": return .tooLarge
            case "gateway/not-found", "draft/not-found": return .unsupported
            default: return .transient
            }
        case .transport(let status) where status == 404:
            return .unsupported
        default:
            return .transient
        }
    }

    private func handleReadFailure(_ error: Error) {
        switch Self.classify(error) {
        case .unsupported:
            // 第一次读就探到不支持：转纯本地并记住（§13.2-11），不报错。
            run(core.capabilityMissing())
        case .conflict, .tooLarge, .transient:
            // 读不回来＝这会儿没对上服务端。不支持（404）不算：那条路永远补不回来，提示会撒谎。
            readFailedOnce = true
            reportSync(true)
            run(core.readFailed())
        }
    }

    private func handleWriteFailure(_ error: Error, text: String) {
        switch Self.classify(error) {
        case .conflict:
            // 决策机接着会要一次 draft/get 取远端当前值，再走五判（§13.2-6）。
            run(core.writeFailed(.conflict(remote: .empty)))
        case .tooLarge:
            run(core.writeFailed(.tooLarge(bytes: DraftSyncCore.utf8ByteCount(of: text))))
        case .unsupported:
            run(core.writeFailed(.unsupported))
        case .transient:
            // 只有网络类失败（含 8 秒超时）进重试队列，才谈得上「恢复后自动补传」。
            reportSync(true)
            run(core.writeTimedOut())
        }
    }

    private func degrade() {
        // 转纯本地后不再谈同步：留着「未同步」提示永远等不到补传，只会撒谎。
        reportSync(false)
        Self.degradedHosts.insert(host)
        // 只写不读：装上插件后应当能自动恢复，所以跨启动不认这条记录，只留给排障查。
        UserDefaults.standard.set(true, forKey: "dsh.draft.degraded." + host)
        debounceTask?.cancel(); debounceTask = nil
        retryTask?.cancel(); retryTask = nil
        Diagnostics.shared.log(.info, "草稿", "该主机没有 draft/*，转纯本地：\(host)")
    }

    // MARK: - 线格式

    /// 一次 RPC，最多等 `requestTimeout` 秒：超时即取消在飞请求，按失败处理（§13.2-5）。
    /// 竞速写法与 `DshConversationView.sendPrompt` 同。
    private static func call(_ caller: DraftCaller, _ endpoint: String, _ args: JSONValue) async throws -> JSONValue {
        let rpc = Task { try await caller.call(endpoint, args) }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(DraftSyncCore.requestTimeout * 1_000_000_000))
            rpc.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await rpc.value
        } catch {
            throw rpc.isCancelled ? DraftRequestTimedOut() : error
        }
    }

    /// 响应体 `{ sessionId, text, updatedAt }`（§10.1）。
    ///
    /// 只要 value 本身是对象就认：字段缺了按「空草稿」补齐（`text` 空串、`updatedAt` 0 本来就是
    /// 「无草稿」的合法写法），别让一个字段把整次读判死。返回 nil 只留给「压根不是对象」。
    private static func snapshot(_ value: JSONValue) -> DraftSnapshot? {
        guard let object = value.objectValue else { return nil }
        let text = object["text"]?.stringValue ?? ""
        let updatedAt = object["updatedAt"]?.intValue ?? 0
        return DraftSnapshot(text: text, updatedAt: updatedAt)
    }

    /// 形状不认识时留一段原始响应（截 200 字符）：下次直接照着日志定位，不用再猜。
    private static func excerpt(_ value: JSONValue) -> String {
        let raw = (try? value.encoded()).flatMap { String(data: $0, encoding: .utf8) }
            ?? String(describing: value)
        return raw.count <= 200 ? raw : String(raw.prefix(200)) + "…"
    }

    /// 未同步状态只按翻转上报：每次重试失败都报一遍，提示条与日志都会被刷成噪声。
    private func reportSync(_ value: Bool) {
        guard unsynced != value else { return }
        unsynced = value
        if value {
            Diagnostics.shared.log(.warn, "草稿", "未同步，等网络恢复后补传")
        } else {
            Diagnostics.shared.log(.info, "草稿", "已同步")
        }
        onSyncState?(value)
    }
}

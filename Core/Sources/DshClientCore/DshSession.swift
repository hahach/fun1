import Foundation
import Crypto
import Citadel

/// 一次完整的接续：SSH 连接 → 本地转发 → 取 token → 换 cookie。
///
/// **两根链条分开**：`SSH 通` 与 `dsh 通`。`connection.connect()` 成功之后，解析 dsh 目标 /
/// 起本地转发 / 隧道自检 / 取凭据任一步失败都**不拆 SSH 连接**，而是进「SSH 已就绪、
/// dsh 未就绪」的降级态（`degraded`）：连接留在实例上，可 `openShell()` 上去自救
/// （把 dsh 重启回来），也可 `retryDsh()` 复用同一条 SSH 重试。
///
/// 退化路径（逐条对应实现位置）：
/// ① **SSH 也连不上**（`connection.connect()` 失败）→ 关闭连接并抛原错误，不建降级态。
///    见 `establish(...)` 与 `restart(...)` 的 `connect()` catch。
/// ② **降级态下 SSH 已死** → `openShell()` / `retryDsh()` 抛 `DshSessionError.sshUnavailable`，
///    不 crash、不静默；由上层决定整栈重建。见 `openShell(...)` 的 catch 与
///    `runDshChain(...)` 的 catch（`DshFailureRules.sshUnavailableReason`）。
/// ③ **转发已启动但 dsh 自检/取凭据失败** → 转发停掉、连接留着。见 `runDshChain(...)` 的 catch。
/// ④ **降级态被 `close()`** → 连接关闭、`degraded` 复位。见 `close()`。
///
/// 并发：重连会换掉整个连接栈，且读写来自不同执行器（网络监听触发的重建在非主
/// 上下文跑）：可变状态一律走锁，锁不跨 await 持有。
public final class DshSession: @unchecked Sendable {
    public enum Stage: Equatable, Sendable {
        case connecting
        case forwarding(localPort: Int)
        case authenticating
        case ready
    }

    public let endpoint: Endpoint

    private let stateLock = NSLock()
    private var _localPort: Int
    private var _credentials: DshCredentials
    /// 降级态下连接仍在（开 shell / 重试 dsh 都要用它）；`close()` 后为 nil。
    private var _connection: SSHClientConnection?
    /// 只有 dsh 就绪时才留转发器：降级态下端口不悬着（见 `markDegraded`）。
    private var _forwarder: LocalForwarder?
    private var _knownHosts: KnownHosts
    private var _degraded: Degraded?

    /// 隧道本地端口。降级态下是上一轮的旧值（0 表示还没建过隧道），**不要**拿它建传输层。
    public private(set) var localPort: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _localPort }
        set { stateLock.lock(); _localPort = newValue; stateLock.unlock() }
    }

    /// dsh 凭据。降级态下是旧值或空值，同样不要拿它建传输层。
    public private(set) var credentials: DshCredentials {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _credentials }
        set { stateLock.lock(); _credentials = newValue; stateLock.unlock() }
    }

    /// 降级态：非 nil 即「SSH 已连、dsh 未就绪」；就绪、未连接或已 `close()` 时为 nil。
    ///
    /// 调用方（`DshTransport` / 连接页）读 `degraded?.message` 就能拿到
    /// 「SSH 已连、dsh 未就绪：<原因>」这句话，据此放出「开 shell」「重试 dsh」两个动作。
    public private(set) var degraded: Degraded? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _degraded }
        set { stateLock.lock(); _degraded = newValue; stateLock.unlock() }
    }

    public var isDegraded: Bool { degraded != nil }

    /// 当前已知主机表（含本次 TOFU 新记的条目）。
    /// 降级态下 `restart()` 抛错、拿不到返回值，调用方从这里回写档案。
    public var knownHostsSnapshot: KnownHosts { knownHosts }

    private var connection: SSHClientConnection? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _connection }
        set { stateLock.lock(); _connection = newValue; stateLock.unlock() }
    }

    private var forwarder: LocalForwarder? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _forwarder }
        set { stateLock.lock(); _forwarder = newValue; stateLock.unlock() }
    }

    /// 当前已知主机表：首次连接由 TOFU 追加，整栈重建要沿用它。
    private var knownHosts: KnownHosts {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _knownHosts }
        set { stateLock.lock(); _knownHosts = newValue; stateLock.unlock() }
    }

    private let fetcher: HTTPFetching
    private let key: Curve25519.Signing.PrivateKey
    private let onHostKey: @Sendable (TOFUHostKeyDelegate.Decision) -> Void

    /// SSH 连上、dsh 还没跑起来时也要能造出实例（降级态就住在这上面），
    /// 故端口与凭据先给占位值，由 `publish(...)` 在 dsh 就绪时覆盖。
    private init(
        connection: SSHClientConnection,
        endpoint: Endpoint,
        fetcher: HTTPFetching,
        key: Curve25519.Signing.PrivateKey,
        knownHosts: KnownHosts,
        onHostKey: @escaping @Sendable (TOFUHostKeyDelegate.Decision) -> Void
    ) {
        self._connection = connection
        self._forwarder = nil
        self._localPort = 0
        self._credentials = DshCredentials(cookieName: "", cookieValue: "")
        self.endpoint = endpoint
        self.fetcher = fetcher
        self.key = key
        self._knownHosts = knownHosts
        self._degraded = nil
        self.onHostKey = onHostKey
    }

    // MARK: - 建会话

    /// 打开会话；`onStage` 供界面显示进度，`onHostKey` 供显示首次连接指纹。
    ///
    /// 隧道建好后先自检：端口无响应就整栈重建一次（新建会话的首个 direct-tcpip
    /// 通道偶发挂住），仍不通才判失败——不把「隧道死了」误报成「token 不对」。
    /// dsh 那几步失败时拆栈抛错（退化路径①之外的「dsh 不通」在这里仍按失败处理；
    /// 要留连接自救请用 `openDegrading(...)`）。
    public static func open(
        endpoint: Endpoint,
        key: Curve25519.Signing.PrivateKey,
        knownHosts: KnownHosts = KnownHosts(),
        fetcher: HTTPFetching,
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onHostKey: @escaping @Sendable (TOFUHostKeyDelegate.Decision) -> Void = { _ in },
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> (session: DshSession, knownHosts: KnownHosts) {
        try await establish(
            endpoint: endpoint,
            key: key,
            knownHosts: knownHosts,
            fetcher: fetcher,
            onStage: onStage,
            onHostKey: onHostKey,
            onAttempt: onAttempt,
            degradeOnDshFailure: false
        )
    }

    /// 与 `open` 同一条链路，只差一处：dsh 那几步失败时**不拆 SSH 连接**，
    /// 把降级会话交回调用方（`session.degraded != nil`），供其开 shell 自救。
    ///
    /// 调用方注意：降级会话的 `localPort` 为 0、`credentials` 为空——**不要**拿它建传输层；
    /// 先 `openShell()` 让用户把 dsh 拉起来，再 `retryDsh()`，成功后才建传输层。
    /// 首连那次「隧道不通就整栈重建」仍保留，发生在降级之前。
    public static func openDegrading(
        endpoint: Endpoint,
        key: Curve25519.Signing.PrivateKey,
        knownHosts: KnownHosts = KnownHosts(),
        fetcher: HTTPFetching,
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onHostKey: @escaping @Sendable (TOFUHostKeyDelegate.Decision) -> Void = { _ in },
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> (session: DshSession, knownHosts: KnownHosts) {
        try await establish(
            endpoint: endpoint,
            key: key,
            knownHosts: knownHosts,
            fetcher: fetcher,
            onStage: onStage,
            onHostKey: onHostKey,
            onAttempt: onAttempt,
            degradeOnDshFailure: true
        )
    }

    private static func establish(
        endpoint: Endpoint,
        key: Curve25519.Signing.PrivateKey,
        knownHosts: KnownHosts,
        fetcher: HTTPFetching,
        onStage: @escaping @Sendable (Stage) -> Void,
        onHostKey: @escaping @Sendable (TOFUHostKeyDelegate.Decision) -> Void,
        onAttempt: @escaping @Sendable (String) -> Void,
        degradeOnDshFailure: Bool
    ) async throws -> (session: DshSession, knownHosts: KnownHosts) {
        var lastError: Error = BootstrapError.noCookie
        for attempt in 1...2 {
            onStage(.connecting)
            let connection = SSHClientConnection(endpoint: endpoint, key: key, knownHosts: knownHosts, onHostKey: onHostKey)
            let hosts: KnownHosts
            do {
                hosts = try await connection.connect()
            } catch {
                // 退化路径①：SSH 也连不上 → 关闭并抛错（与改造前一致，没有可自救的东西）。
                await connection.close()
                throw error
            }

            // SSH 已就绪：从这里往下失败都不拆连接（退化路径③）。
            let session = DshSession(
                connection: connection,
                endpoint: endpoint,
                fetcher: fetcher,
                key: key,
                knownHosts: hosts,
                onHostKey: onHostKey
            )
            let forwarder = LocalForwarder()
            do {
                let result = try await session.runDshChain(
                    on: connection,
                    forwarder: forwarder,
                    onStage: onStage,
                    onAttempt: onAttempt
                )
                session.publish(forwarder: forwarder, port: result.port, credentials: result.credentials)
                onStage(.ready)
                return (session, hosts)
            } catch {
                lastError = error
                await forwarder.stop()
                if attempt == 1, isTunnelProblem(error) {
                    await connection.close()
                    onAttempt("隧道未就绪，整栈重建一次")
                    continue
                }
                if degradeOnDshFailure, let value = (error as? DshSessionError)?.degraded {
                    // 降级：连接留着（已在实例上），转发已停，交给调用方开 shell 自救。
                    session.markDegraded(value)
                    return (session, hosts)
                }
                await connection.close()
                throw error
            }
        }
        throw lastError
    }

    /// 首连时「隧道这一层不通」才值得整栈重建一次：token 不对重建也没用。
    static func isTunnelProblem(_ error: Error) -> Bool {
        (error as? DshSessionError)?.degraded?.isTunnelProblem == true
    }

    // MARK: - dsh 链路（SSH 已就绪之后）

    private struct DshChainResult {
        let port: Int
        let credentials: DshCredentials
    }

    /// SSH 已就绪之后的 dsh 链路：解析 → 转发 → 自检 → 取凭据。
    ///
    /// 失败时把已起的转发停掉（**连接一律不动**），并按两种可区分的情形抛错：
    /// - `.sshUnavailable`：SSH 这一层已死（旧连接上开 channel / exec 报通道已关），
    ///   复用没有意义，由调用方整栈重建；
    /// - `.dshNotReady`：SSH 通、dsh 不通，连接留给 `openShell()` / `retryDsh()`。
    ///
    /// `onStep` 在每次进入新阶段前回调一次（重试路径用它打「重试 dsh：<阶段>」）。
    private func runDshChain(
        on connection: SSHClientConnection,
        forwarder: LocalForwarder,
        onStage: @escaping @Sendable (Stage) -> Void,
        onAttempt: @escaping @Sendable (String) -> Void,
        onStep: (@Sendable (Degraded.Stage) -> Void)? = nil
    ) async throws -> DshChainResult {
        var step = Degraded.Stage.resolve
        onStep?(step)
        do {
            let target = try await DshBootstrap.resolve(runner: connection, onAttempt: onAttempt)

            step = .forward
            onStep?(step)
            let port = try await forwarder.start(client: try connection.sshClient(), targetPort: target.port)
            onStage(.forwarding(localPort: port))

            step = .probe
            onStep?(step)
            let probe = await Self.probeWithRetry(localPort: port, onAttempt: onAttempt)
            onAttempt("隧道自检（远端 \(target.port)）：\(probe.summary)")
            if !probe.isAlive {
                throw BootstrapError.tunnelUnreachable(reason: probe.summary)
            }

            step = .authenticate
            onStep?(step)
            onStage(.authenticating)
            let credentials = try await DshBootstrap.run(
                fetcher: fetcher,
                localPort: port,
                candidates: target.candidates,
                onAttempt: onAttempt
            )
            return DshChainResult(port: port, credentials: credentials)
        } catch {
            // 退化路径③：转发已起就停（端口别悬着），连接留着。
            await forwarder.stop()
            if let reason = DshFailureRules.sshUnavailableReason(error) {
                throw DshSessionError.sshUnavailable(reason: reason)
            }
            throw DshSessionError.dshNotReady(DshFailureRules.degraded(stage: step, error: error))
        }
    }

    /// 自检一次不通过时再探一次：本地连接刚建好时的首个请求偶发无响应，
    /// 单次结果不足以判隧道死。
    static func probeWithRetry(
        localPort: Int,
        onAttempt: @escaping @Sendable (String) -> Void
    ) async -> TunnelProbe {
        let first = await TunnelProbe.check(localPort: localPort, timeout: 3)
        guard !first.isAlive else { return first }
        onAttempt("隧道自检未通过（\(first.summary)），复探一次")
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await TunnelProbe.check(localPort: localPort, timeout: 3)
    }

    // MARK: - 状态发布

    /// 发布成功结果：转发、端口、凭据一起换新，降级态清掉。
    private func publish(forwarder: LocalForwarder, port: Int, credentials: DshCredentials) {
        self.forwarder = forwarder
        self.localPort = port
        self.credentials = credentials
        self.degraded = nil
    }

    /// 进降级态：连接留着（`openShell`/`retryDsh` 要用），转发不留（端口别悬着）。
    private func markDegraded(_ value: Degraded) {
        self.forwarder = nil
        self.degraded = value
        CoreLog.shared.log(.warn, "连接", "SSH 已就绪，dsh 未就绪：\(value.reason)")
    }

    // MARK: - 对外

    /// 隧道内访问 dsh 的基础 URL（不带 token）。降级态下端口是旧值，不要用。
    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(localPort)/")!
    }

    /// 重新取 token 换 cookie：dsh 重启、token 轮换、或收到 401 时调用。
    /// 隧道与 SSH 连接保持不变。降级态下没有可用端口，先 `retryDsh()`。
    public func refreshCredentials() async throws -> DshCredentials {
        if let value = degraded {
            throw DshSessionError.dshNotReady(value)
        }
        guard let connection = connection else {
            throw DshSessionError.notConnected
        }
        let fresh = try await DshBootstrap.run(runner: connection, fetcher: fetcher, localPort: localPort)
        credentials = fresh
        return fresh
    }

    /// 整栈重建：SSH 连接与本地转发都可能已被系统掐断（后台挂起后回前台最常见），
    /// 这时在旧连接上开 channel 只会得到 `creatingChannelAfterClosure`、连本地端口也已不监听。
    /// 重建后 `localPort` 与 `credentials` 都会变，调用方须重建传输层。
    ///
    /// 与改造前唯一的差别：`connect()` 成功之后 dsh 那几步失败时**不再拆 SSH 连接**，
    /// 而是停掉转发、留下连接、置 `degraded`，再抛 `DshSessionError.dshNotReady`。
    /// SSH 这一层若在 dsh 链路中途死掉（`.sshUnavailable`），没有可自救的连接，收掉后抛错。
    /// - Returns: 本次的已知主机表，供调用方回写（首次连接会多一条）。
    @discardableResult
    public func restart(
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> KnownHosts {
        // 一实例只留一条 SSH：旧的（含降级态留下的那条）先收干净，免得两条并存。
        await close()
        onStage(.connecting)
        let connection = SSHClientConnection(endpoint: endpoint, key: key, knownHosts: knownHosts, onHostKey: onHostKey)
        let hosts: KnownHosts
        do {
            hosts = try await connection.connect()
        } catch {
            // 退化路径①：SSH 也连不上 → 关闭并抛错（现状不变）。
            await connection.close()
            throw error
        }

        let forwarder = LocalForwarder()
        do {
            let result = try await runDshChain(
                on: connection,
                forwarder: forwarder,
                onStage: onStage,
                onAttempt: onAttempt
            )
            self.connection = connection
            self.knownHosts = hosts
            publish(forwarder: forwarder, port: result.port, credentials: result.credentials)
            onStage(.ready)
            return hosts
        } catch let error as DshSessionError {
            if let value = error.degraded {
                // 退化路径③：转发已在 runDshChain 里停掉，连接留在实例上供自救。
                self.connection = connection
                self.knownHosts = hosts
                markDegraded(value)
                throw error
            }
            // 退化路径②的写侧：SSH 在 dsh 链路中途死了，没有可自救的连接。
            await connection.close()
            throw error
        } catch {
            // runDshChain 只抛 DshSessionError；这条兜底只为编译期的穷尽性，
            // 真进来了也按「连不上」处理，不留半死连接。
            await connection.close()
            throw error
        }
    }

    /// 复用当前 SSH 连接重跑「解析 → 转发 → 自检 → 取凭据」。
    ///
    /// 成功即从降级态升回就绪：`localPort`/`credentials` 换新、`degraded` 清空。
    /// 失败时更新降级态并抛错；SSH 已死（`creatingChannelAfterClosure` 一类）抛
    /// `.sshUnavailable`，让上层决定整栈重建——这里不关连接，免得把上层手里的会话变成半死状态。
    public func retryDsh(
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        guard let connection = connection else {
            // 退化路径②（无连接侧）：没连过或已 close()。
            CoreLog.shared.log(.warn, "连接", "复用 SSH 重试 dsh 失败：SSH 尚未连接")
            throw DshSessionError.notConnected
        }
        // 幂等：上一轮可能留下转发（调用方只判了某一步），先收掉再重起。
        if let stale = forwarder {
            await stale.stop()
            self.forwarder = nil
        }
        let forwarder = LocalForwarder()
        do {
            let result = try await runDshChain(
                on: connection,
                forwarder: forwarder,
                onStage: onStage,
                onAttempt: onAttempt,
                onStep: { step in
                    CoreLog.shared.log(.info, "连接", "复用 SSH 重试 dsh：\(DshFailureRules.stageLabel(step))")
                }
            )
            publish(forwarder: forwarder, port: result.port, credentials: result.credentials)
            onStage(.ready)
            CoreLog.shared.log(.info, "连接", "复用 SSH 重试 dsh 成功（本地端口 \(result.port)）")
        } catch let error as DshSessionError {
            switch error {
            case .dshNotReady(let value):
                markDegraded(value)
                CoreLog.shared.log(.warn, "连接", "复用 SSH 重试 dsh 失败（\(value.stageLabel)）：\(value.reason)")
            case .sshUnavailable(let reason):
                CoreLog.shared.log(.warn, "连接", "复用 SSH 重试 dsh 失败：SSH 不可用（\(reason)）")
            case .notConnected:
                CoreLog.shared.log(.warn, "连接", "复用 SSH 重试 dsh 失败：SSH 尚未连接")
            }
            throw error
        } catch {
            throw error
        }
    }

    /// 复用同一条 SSH 连接开一条交互 shell（dsh 挂了时的自救通道）。
    ///
    /// 连上过（就绪或降级态）就能开；没连接、或连接已死时抛 `DshSessionError`，
    /// 不 crash、不静默。调用方负责 `TTYChannel.close()`。
    public func openShell(cols: Int = 100, rows: Int = 30) async throws -> TTYChannel {
        let current = connection
        CoreLog.shared.log(.info, "终端", "开 shell（SSH=\(DshFailureRules.sshState(connected: current != nil, degraded: degraded))）")
        guard let current = current else {
            // 退化路径②（无连接侧）：没连过或已 close()。
            throw DshSessionError.notConnected
        }
        do {
            return try await current.openTTY(cols: cols, rows: rows)
        } catch {
            if let reason = DshFailureRules.sshUnavailableReason(error) {
                // 退化路径②：降级态下 SSH 已死。
                CoreLog.shared.log(.warn, "终端", "开 shell 失败：SSH 不可用（\(reason)）")
                throw DshSessionError.sshUnavailable(reason: reason)
            }
            throw error
        }
    }

    /// 旧入口：与 `openShell` 同一条路径（终端页现用这个）。
    public func openTTY(cols: Int = 100, rows: Int = 30) async throws -> TTYChannel {
        try await openShell(cols: cols, rows: rows)
    }

    /// 在已建立的 SSH 连接上跑一条命令（调试日志用）。降级态同样可用。
    public func runRemote(_ command: String) async throws -> String {
        guard let connection = connection else {
            throw DshSessionError.notConnected
        }
        return try await connection.run(command)
    }

    /// 关掉转发与连接（降级态也要收干净），状态复位。
    ///
    /// 顺序：先摘状态（并发的 `openShell()` 立刻看到「没连接」），再停转发、关 SSH。
    /// 退化路径④：降级态被 `close()` → 连接关闭、`degraded` 复位。
    public func close() async {
        let forwarder = self.forwarder
        let connection = self.connection
        self.forwarder = nil
        self.connection = nil
        self.degraded = nil
        await forwarder?.stop()
        await connection?.close()
    }
}

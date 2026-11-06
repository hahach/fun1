import Foundation
import Crypto
import Citadel

/// 一次完整的接续：SSH 连接 → 本地转发 → 取 token → 换 cookie。
public final class DshSession: @unchecked Sendable {
    public enum Stage: Equatable, Sendable {
        case connecting
        case forwarding(localPort: Int)
        case authenticating
        case ready
    }

    public let endpoint: Endpoint

    /// 重连会换掉整个连接栈，且读写来自不同执行器（网络监听触发的重建在非主
    /// 上下文跑）：可变状态一律走锁，锁不跨 await 持有。
    private let stateLock = NSLock()
    private var _localPort: Int
    private var _credentials: DshCredentials
    private var _connection: SSHClientConnection
    private var _forwarder: LocalForwarder

    public private(set) var localPort: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _localPort }
        set { stateLock.lock(); _localPort = newValue; stateLock.unlock() }
    }

    public private(set) var credentials: DshCredentials {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _credentials }
        set { stateLock.lock(); _credentials = newValue; stateLock.unlock() }
    }

    private var connection: SSHClientConnection {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _connection }
        set { stateLock.lock(); _connection = newValue; stateLock.unlock() }
    }

    private var forwarder: LocalForwarder {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _forwarder }
        set { stateLock.lock(); _forwarder = newValue; stateLock.unlock() }
    }

    private let fetcher: HTTPFetching
    private let key: Curve25519.Signing.PrivateKey
    private let knownHosts: KnownHosts
    private let onHostKey: @Sendable (TOFUHostKeyDelegate.Decision) -> Void

    private init(
        connection: SSHClientConnection,
        forwarder: LocalForwarder,
        localPort: Int,
        credentials: DshCredentials,
        endpoint: Endpoint,
        fetcher: HTTPFetching,
        key: Curve25519.Signing.PrivateKey,
        knownHosts: KnownHosts,
        onHostKey: @escaping @Sendable (TOFUHostKeyDelegate.Decision) -> Void
    ) {
        self._connection = connection
        self._forwarder = forwarder
        self._localPort = localPort
        self._credentials = credentials
        self.endpoint = endpoint
        self.fetcher = fetcher
        self.key = key
        self.knownHosts = knownHosts
        self.onHostKey = onHostKey
    }

    /// 打开会话；`onStage` 供界面显示进度，`onHostKey` 供显示首次连接指纹。
    ///
    /// 隧道建好后先自检：端口无响应就整栈重建一次（新建会话的首个 direct-tcpip
    /// 通道偶发挂住），仍不通才判失败——不把「隧道死了」误报成「token 不对」。
    public static func open(
        endpoint: Endpoint,
        key: Curve25519.Signing.PrivateKey,
        knownHosts: KnownHosts = KnownHosts(),
        fetcher: HTTPFetching,
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onHostKey: @escaping @Sendable (TOFUHostKeyDelegate.Decision) -> Void = { _ in },
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> (session: DshSession, knownHosts: KnownHosts) {
        var lastError: Error = BootstrapError.noCookie
        for attempt in 1...2 {
            onStage(.connecting)
            let connection = SSHClientConnection(endpoint: endpoint, key: key, knownHosts: knownHosts, onHostKey: onHostKey)
            let forwarder = LocalForwarder()
            do {
                let hosts = try await connection.connect()
                let target = try await DshBootstrap.resolve(runner: connection, onAttempt: onAttempt)
                let port = try await forwarder.start(client: try connection.sshClient(), targetPort: target.port)
                onStage(.forwarding(localPort: port))

                let probe = await Self.probeWithRetry(localPort: port, onAttempt: onAttempt)
                onAttempt("隧道自检（远端 \(target.port)）：\(probe.summary)")
                if !probe.isAlive {
                    await forwarder.stop()
                    await connection.close()
                    lastError = BootstrapError.tunnelUnreachable(reason: probe.summary)
                    if attempt == 1 {
                        onAttempt("隧道未就绪，整栈重建一次")
                        continue
                    }
                    break
                }

                onStage(.authenticating)
                let credentials = try await DshBootstrap.run(
                    fetcher: fetcher,
                    localPort: port,
                    candidates: target.candidates,
                    onAttempt: onAttempt
                )
                onStage(.ready)
                let session = DshSession(
                    connection: connection,
                    forwarder: forwarder,
                    localPort: port,
                    credentials: credentials,
                    endpoint: endpoint,
                    fetcher: fetcher,
                    key: key,
                    knownHosts: knownHosts,
                    onHostKey: onHostKey
                )
                return (session, hosts)
            } catch {
                lastError = error
                await forwarder.stop()
                await connection.close()
                if attempt == 1, (error as? BootstrapError)?.isTunnelProblem == true {
                    onAttempt("隧道未就绪，整栈重建一次")
                    continue
                }
                throw error
            }
        }
        throw lastError
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

    /// 隧道内访问 dsh 的基础 URL（不带 token）。
    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(localPort)/")!
    }

    /// 重新取 token 换 cookie：dsh 重启、token 轮换、或收到 401 时调用。
    /// 隧道与 SSH 连接保持不变。
    public func refreshCredentials() async throws -> DshCredentials {
        let fresh = try await DshBootstrap.run(runner: connection, fetcher: fetcher, localPort: localPort)
        credentials = fresh
        return fresh
    }

    /// 整栈重建：SSH 连接与本地转发都可能已被系统掐断（后台挂起后回前台最常见），
    /// 这时在旧连接上开 channel 只会得到 `creatingChannelAfterClosure`、连本地端口也已不监听。
    /// 重建后 `localPort` 与 `credentials` 都会变，调用方须重建传输层。
    /// - Returns: 本次的已知主机表，供调用方回写（首次连接会多一条）。
    @discardableResult
    public func restart(
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onAttempt: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> KnownHosts {
        await close()
        onStage(.connecting)
        let connection = SSHClientConnection(endpoint: endpoint, key: key, knownHosts: knownHosts, onHostKey: onHostKey)
        let forwarder = LocalForwarder()
        do {
            let hosts = try await connection.connect()
            let target = try await DshBootstrap.resolve(runner: connection, onAttempt: onAttempt)
            let port = try await forwarder.start(client: try connection.sshClient(), targetPort: target.port)
            onStage(.forwarding(localPort: port))

            let probe = await Self.probeWithRetry(localPort: port, onAttempt: onAttempt)
            onAttempt("隧道自检（远端 \(target.port)）：\(probe.summary)")
            if !probe.isAlive {
                await forwarder.stop()
                await connection.close()
                throw BootstrapError.tunnelUnreachable(reason: probe.summary)
            }

            onStage(.authenticating)
            let fresh = try await DshBootstrap.run(
                fetcher: fetcher,
                localPort: port,
                candidates: target.candidates,
                onAttempt: onAttempt
            )
            self.connection = connection
            self.forwarder = forwarder
            self.localPort = port
            self.credentials = fresh
            onStage(.ready)
            return hosts
        } catch {
            await forwarder.stop()
            await connection.close()
            throw error
        }
    }

    /// 复用同一条 SSH 连接开交互 shell。
    /// 在已建立的 SSH 连接上跑一条命令（调试日志用）。
    public func runRemote(_ command: String) async throws -> String {
        try await connection.run(command)
    }

    public func openTTY(cols: Int = 100, rows: Int = 30) async throws -> TTYChannel {
        try await connection.openTTY(cols: cols, rows: rows)
    }

    public func close() async {
        await forwarder.stop()
        await connection.close()
    }
}
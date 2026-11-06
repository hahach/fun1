import Foundation
import DshClientCore
#if canImport(Network)
import Network
#endif

/// 连接自愈完成（轻量重连或整栈重建）：上层据此清掉过期的错误提示并重拉数据。
extension Notification.Name {
    static let dshTransportRecovered = Notification.Name("dsh.transport.recovered")
    /// 网络不可用：上层给出断网提示；流被主动断掉以露出断开 UI（否则挂到超时）。
    static let dshTransportNetworkLost = Notification.Name("dsh.transport.networkLost")
    /// 开始自动重连（长流静默或断开后进入退避重试）：上层据此显示「正在重连」。
    /// 没有这条通知时，长流半死期间界面什么都不显示——RPC 还能通，列表照常返回（B-152）。
    static let dshTransportRecovering = Notification.Name("dsh.transport.recovering")
}

/// 连接在界面上的三态：只表达「现在能不能用」，不解释原因。
enum DshLinkState: Equatable {
    case ok
    case reconnecting
    case offline
}

/// 把 rowel 的端点层直接架在 dsh 的 mux 上：不再经过 Bridle，也不做 Noise。
///
/// `call` 走 `POST /api/<endpoint>`，`open` 走 `/api/remote.mux` 的逻辑流；
/// 两者的线格式在 Core 里已有实现，这里只做 `JSONValue` 与 `Any` 的换算。
final class DshTransport: HarnessTransport, @unchecked Sendable {
    /// 网络监听触发的重连在非主上下文跑，rpc/mux 会与界面线程并发读写，一律走锁。
    private let stateLock = NSLock()
    private var _rpc: DshRPC
    /// 整栈重连后本地端口与凭据都会变，故不是常量。
    private var _mux: DshMux

    private var rpc: DshRPC {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _rpc }
        set { stateLock.lock(); _rpc = newValue; stateLock.unlock() }
    }

    private var mux: DshMux {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _mux }
        set { stateLock.lock(); _mux = newValue; stateLock.unlock() }
    }
    /// 终端页复用同一条 SSH 连接。
    let dshSession: DshSession
    /// 单飞：同一时刻只跑一次重连。
    private let refreshLock = NSLock()
    private var refreshing: Task<Void, Error>?
    /// 前台网络恢复自动重连：回前台触发覆盖不了「人留在 App 内、网络断又来」（B-116）。
    private let pathMonitor = NWPathMonitor()
    private let netLock = NSLock()
    private var netSatisfied = true

    init(session: DshSession) {
        dshSession = session
        // init 内直写后备存储：锁版访问器在全部存储属性就位前不可用。
        _rpc = DshRPC(baseURL: session.baseURL, credentials: session.credentials)
        _mux = DshMux(port: session.localPort, credentials: session.credentials)
        armLiveness(_mux)
        startNetworkMonitor()
    }

    /// 当前网络路径是否可用（NWPathMonitor 口径）：断网期间的自动重连触发者据此放弃尝试。
    var isNetworkSatisfied: Bool {
        netLock.lock(); defer { netLock.unlock() }
        return netSatisfied
    }

    deinit {
        pathMonitor.cancel()
        recovery?.cancel()
    }

    /// 长流的两条失败信号：静默（对端没了但收不到 FIN）与断开（对端 close / 读错误）。
    /// 都交给同一个退避重连，不再等用户点横幅。
    private func armLiveness(_ mux: DshMux) {
        let timeout = mux.silenceTimeout
        mux.onSilence = { [weak self] in
            guard let self else { return }
            Diagnostics.shared.log(.warn, "传输", "长流静默超过 \(Int(timeout)) 秒，判定已断开")
            self.scheduleRecovery(trigger: "长流静默")
        }
        mux.onLost = { [weak self] reason in
            guard let self else { return }
            Diagnostics.shared.log(.warn, "传输", "长流断开：\(reason)")
            self.scheduleRecovery(trigger: "长流断开")
        }
    }

    private let recoveryLock = NSLock()
    private var recovery: Task<Void, Never>?

    /// 断线自愈：500 ms 起、×2、上限 10 秒，成功即停——对齐上游浏览器的重连节奏。
    /// 重连本身走 refresh 的单飞锁，与手动点横幅并发时只会跑一次。
    private func scheduleRecovery(trigger: String) {
        recoveryLock.lock()
        if recovery != nil { recoveryLock.unlock(); return }
        let task = Task { [weak self] in
            var delay: TimeInterval = 0.5
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if !self.isNetworkSatisfied {
                    delay = min(delay * 2, 10)
                    continue
                }
                do {
                    try await self.refresh(trigger: trigger)
                    Diagnostics.shared.log(.info, "传输", "自动重连成功（\(trigger)）")
                    break
                } catch {
                    Diagnostics.shared.log(.warn, "传输", "自动重连失败：\(DshBoard.message(error))（\(trigger)）")
                    delay = min(delay * 2, 10)
                }
            }
            guard let self else { return }
            self.recoveryLock.lock(); self.recovery = nil; self.recoveryLock.unlock()
        }
        recovery = task
        recoveryLock.unlock()
        NotificationCenter.default.post(name: .dshTransportRecovering, object: nil)
    }

    /// 网络整体不可用时不重试：留给 NWPathMonitor，恢复后再连。
    private func cancelRecovery() {
        recoveryLock.lock()
        recovery?.cancel()
        recovery = nil
        recoveryLock.unlock()
    }

    /// 只在「满足 ↔ 不满足」跳变时动作：网络恢复后延迟一拍再单飞重连，
    /// 让路径先稳定、也把多次跳变合并成一次。
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            self.netLock.lock()
            let wasSatisfied = self.netSatisfied
            self.netSatisfied = satisfied
            self.netLock.unlock()
            guard wasSatisfied != satisfied else { return }
            if !satisfied {
                Diagnostics.shared.log(.warn, "传输", "网络不可用")
                NotificationCenter.default.post(name: .dshTransportNetworkLost, object: nil)
                self.cancelRecovery()
                // 主动断流：mux 的流在断网时不失败（无 RST），会话页会永远停在「载入中」；
                // 断掉让跟随流立刻失败，露出既有的「连接已中断」横幅。
                Task { await self.mux.close() }
                return
            }
            Diagnostics.shared.log(.info, "传输", "网络恢复，1 秒后自动重连")
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do { try await self.refresh(trigger: "网络恢复") }
                catch { Diagnostics.shared.log(.warn, "传输", "网络恢复后重连失败：\(DshBoard.message(error))") }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dsh.netpath"))
    }

    /// 调试日志用：在已建立的 SSH 连接上跑一条命令。
    func runRemote(_ command: String) async throws -> String {
        try await dshSession.runRemote(command)
    }

    /// 建立 mux 的物理连接；失败会让所有流立刻报错。
    func connect() async throws {
        try await mux.connect()
    }

    /// 凭据失效或流断开时重建。
    ///
    /// 单飞：并发调用合并成一次（同一时刻只允许一个重连在跑，其余等待同一结果）。
    /// 轻量路径前先探本地端口——SSH 已死时它必然失败，白等一个超时只会让界面多抖一次。
    func refresh(trigger: String = "未标注") async throws {
        refreshLock.lock()
        if let inFlight = refreshing {
            refreshLock.unlock()
            Diagnostics.shared.log(.info, "传输", "重连已在途，合并本次请求（\(trigger)）")
            return try await inFlight.value
        }
        let task = Task<Void, Error> { [self] in
            defer {
                refreshLock.lock()
                refreshing = nil
                refreshLock.unlock()
            }
            try await performRefresh(trigger: trigger)
        }
        refreshing = task
        refreshLock.unlock()
        return try await task.value
    }

    private func performRefresh(trigger: String) async throws {
        let probe = await TunnelProbe.check(localPort: dshSession.localPort, timeout: 2)
        if probe.isAlive {
            do {
                let fresh = try await dshSession.refreshCredentials()
                rpc = DshRPC(baseURL: dshSession.baseURL, credentials: fresh)
                try await mux.reconnect()
                Diagnostics.shared.log(.info, "传输", "轻量重连成功（\(trigger)）")
                NotificationCenter.default.post(name: .dshTransportRecovered, object: nil)
                return
            } catch {
                Diagnostics.shared.log(.warn, "传输", "轻量重连失败：\(DshBoard.message(error))（\(trigger)）")
            }
        } else {
            Diagnostics.shared.log(.warn, "传输", "本地端口无响应（\(probe.summary)），直接整栈重建（\(trigger)）")
        }
        await mux.close()
        // 刚回前台时整栈重建本身也可能撞上还没散尽的旧套接字（io close channel）。
        // 重试一次，仍失败才把错误交给上层。
        do {
            try await rebuild()
            Diagnostics.shared.log(.info, "传输", "整栈重建成功（\(trigger)）")
            NotificationCenter.default.post(name: .dshTransportRecovered, object: nil)
        } catch {
            Diagnostics.shared.log(.warn, "传输", "整栈重建失败：\(DshBoard.message(error))，600ms 后重试（\(trigger)）")
            try await Task.sleep(nanoseconds: 600_000_000)
            try await rebuild()
            Diagnostics.shared.log(.info, "传输", "整栈重建重试成功（\(trigger)）")
            NotificationCenter.default.post(name: .dshTransportRecovered, object: nil)
        }
    }
    /// 整栈重建：SSH 连接、本地转发、凭据、mux 全部换新。
    private func rebuild() async throws {
        try await dshSession.restart()
        rpc = DshRPC(baseURL: dshSession.baseURL, credentials: dshSession.credentials)
        let rebuilt = DshMux(port: dshSession.localPort, credentials: dshSession.credentials)
        armLiveness(rebuilt)
        try await rebuilt.connect()
        mux = rebuilt
    }

    func call(_ endpoint: String, _ args: JSONValue) async throws -> JSONValue {
        let started = Date()
        do {
            let value = try await rpc.call(endpoint, args: args.toAny())
            if RemoteLog.shared.isEnabled {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Diagnostics.shared.log(.info, "调用", "\(endpoint) 成功 \(ms)ms")
            }
            return JSONValue(any: value)
        } catch {
            Diagnostics.shared.log(.fail, "调用", "\(endpoint)：\(DshBoard.message(error))")
            throw error
        }
    }

    func open(_ endpoint: String, _ args: JSONValue) async -> TunnelStream {
        let sid = UUID().uuidString
        do {
            let stream = try mux.open(endpoint: endpoint, payload: ["args": args.toAny()])
            // 泵任务装进引用盒：消费侧终止与 TunnelStream.cancel 都要能取消它；
            // 取消会结束内层迭代，mux 流的 onTermination 随之把 cancel 帧发给 dsh。
            final class Pump { var task: Task<Void, Never>? }
            let pump = Pump()
            let items = AsyncThrowingStream<JSONValue, Error> { continuation in
                pump.task = Task {
                    do {
                        for try await item in stream {
                            continuation.yield(JSONValue(any: item))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in pump.task?.cancel() }
            }
            return TunnelStream(sid: sid, items: items, cancel: { pump.task?.cancel() })
        } catch {
            let items = AsyncThrowingStream<JSONValue, Error> { $0.finish(throwing: error) }
            return TunnelStream(sid: sid, items: items, cancel: {})
        }
    }
}

extension JSONValue {
    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let items): return items.map { $0.toAny() }
        case .object(let fields): return fields.mapValues { $0.toAny() }
        }
    }
}
import Foundation
import NIOCore
import NIOPosix

/// dsh 的流式接口：一条 WebSocket 上多路复用多个逻辑流。
///
/// 帧格式（来源：`@deepseek-ai/dsh-api-gateway` 的 `RemoteStreamMuxClient`）：
/// 上行 `{type:"open",streamId,endpoint,payload}` / `{type:"item"…}` / `{type:"end"…}` / `{type:"cancel"…}`；
/// 下行 `{type:"item",streamId,value}` / `{type:"end",streamId}` / `{type:"error",streamId,error{code,message,details}}`。
public final class DshMux: @unchecked Sendable {
    public enum MuxError: Error, Equatable {
        case remote(code: String, message: String)
        case malformedFrame
        case closed
    }

    private let host: String
    private let port: Int
    private let credentials: DshCredentials
    private var ws: WebSocketClient
    private let lock = NSLock()
    private var streams: [String: AsyncThrowingStream<Any, Error>.Continuation] = [:]
    private var reader: Task<Void, Never>?
    /// 最后一次收到任何帧（含 Ping/Pong）的时刻。
    private var lastActivity = Date()
    private var watchdog: Task<Void, Never>?
    /// 主动关闭中：reader 结束不算"意外断开"。
    private var closing = false
    /// 连接代次：每次 connect 自增。旧连接的 reader 在重建后才收尾时，
    /// 不能再报"意外断开"——否则会触发一次多余的重连（B-141）。
    private var generation = 0

    /// 多久没有任何帧就判死。服务端每 2 秒发一次 WebSocket Ping，
    /// 正常连接不可能这么久一帧都没有（见 docs/dsh-research/dsh-mux-liveness-and-reconnect.md）。
    public var silenceTimeout: TimeInterval = 15
    /// 静默超时：长流多半已半死，上层据此安排重连。
    public var onSilence: (@Sendable () -> Void)?
    /// 非主动关闭的断开（对端 close / 读错误）：上层据此安排重连。
    public var onLost: (@Sendable (String) -> Void)?

    private let group: EventLoopGroup

    public init(host: String = "127.0.0.1", port: Int, credentials: DshCredentials, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.group = group
        self.ws = WebSocketClient(group: group)
    }

    public func connect() async throws {
        // 每次连接用新的 WebSocketClient：它的入站流在 close 后就结束了，
        // 复用会让重建后的流永远收不到消息。
        ws = WebSocketClient(group: group)
        ws.onActivity = { [weak self] in self?.touch() }
        lock.lock(); closing = false; lastActivity = Date(); generation += 1; let gen = generation; lock.unlock()
        try await ws.connect(.init(
            host: host,
            port: port,
            path: "/api/remote.mux",
            cookie: "\(credentials.cookieName)=\(credentials.cookieValue)"
        ))
        reader = Task { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.environment["DSH_DEBUG"] != nil {
                FileHandle.standardError.write(Data("mux reader started\n".utf8))
            }
            do {
                for try await text in ws.incoming { self.dispatch(text) }
            } catch {
                self.failAll(error)
                self.noteLost("\(error)", generation: gen)
                return
            }
            self.failAll(MuxError.closed)
            self.noteLost("连接已关闭", generation: gen)
        }
        startWatchdog()
    }

    public func open(endpoint: String, payload: Any = ["args": [String: Any]()]) throws -> AsyncThrowingStream<Any, Error> {
        let streamId = UUID().uuidString
        var captured: AsyncThrowingStream<Any, Error>.Continuation!
        let stream = AsyncThrowingStream<Any, Error> { continuation in
            captured = continuation
            // 消费侧取消（离开会话页、迭代 Task 结束）时通知 dsh 停流并清表；
            // 服务端的 end/error 与断线 failAll 走 .finished，不补发 cancel。
            continuation.onTermination = { [weak self] termination in
                guard let self else { return }
                self.lock.lock()
                self.streams.removeValue(forKey: streamId)
                self.lock.unlock()
                guard case .cancelled = termination else { return }
                self.cancel(streamId: streamId)
            }
        }
        lock.lock()
        streams[streamId] = captured
        lock.unlock()

        let frame: [String: Any] = ["type": "open", "streamId": streamId, "endpoint": endpoint, "payload": payload]
        if ProcessInfo.processInfo.environment["DSH_DEBUG"] != nil {
            FileHandle.standardError.write(Data("mux-> \(Self.encode(frame))\n".utf8))
        }
        Task {
            do {
                try await ws.send(Self.encode(frame))
            } catch {
                captured.finish(throwing: error)
            }
        }
        return stream
    }

    /// 通知 dsh 停流（服务端收到 cancel 即终止该流，不再回终态帧）；
    /// 本地同时移除流表项，该 id 的后续帧按未知流丢弃。
    public func cancel(streamId: String) {
        lock.lock()
        let continuation = streams.removeValue(forKey: streamId)
        lock.unlock()
        continuation?.finish()
        let frame: [String: Any] = ["type": "cancel", "streamId": streamId]
        if ProcessInfo.processInfo.environment["DSH_DEBUG"] != nil {
            FileHandle.standardError.write(Data("mux-> \(Self.encode(frame))\n".utf8))
        }
        Task { [weak self] in
            _ = try? await self?.ws.send(Self.encode(frame))
        }
    }

    /// 断线后重建：旧流一律失败，由调用方重新 open。
    public func reconnect() async throws {
        await close()
        try await connect()
    }

    public func close() async {
        lock.lock(); closing = true; lock.unlock()
        watchdog?.cancel()
        watchdog = nil
        reader?.cancel()
        await ws.close()
        failAll(MuxError.closed)
    }

    private func touch() {
        lock.lock(); lastActivity = Date(); lock.unlock()
    }

    /// reader 自己结束：只有不是主动关闭才通知上层。
    private func noteLost(_ reason: String, generation gen: Int) {
        lock.lock()
        let stale = closing || gen != generation
        lock.unlock()
        guard !stale else { return }
        onLost?(reason)
    }

    /// 每 5 秒看一眼有没有帧。服务端心跳是 2 秒一次，静默到阈值说明这条长流
    /// 已经没有对端——iOS 挂起后收不到 FIN，只能靠这个判据发现。
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                self.lock.lock()
                let idle = Date().timeIntervalSince(self.lastActivity)
                let limit = self.silenceTimeout
                self.lock.unlock()
                guard idle > limit else { continue }
                self.onSilence?()
                await self.close()
                return
            }
        }
    }

    private func dispatch(_ text: String) {
        if ProcessInfo.processInfo.environment["DSH_DEBUG"] != nil {
            FileHandle.standardError.write(Data("mux<- \(text.prefix(120))\n".utf8))
        }
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: JSONTolerance.sanitize(data)) as? [String: Any],
              let type = frame["type"] as? String,
              let streamId = frame["streamId"] as? String else { return }
        lock.lock()
        let continuation = streams[streamId]
        lock.unlock()
        guard let continuation else { return }

        switch type {
        case "item":
            continuation.yield(frame["value"] ?? NSNull())
        case "end":
            lock.lock(); streams[streamId] = nil; lock.unlock()
            continuation.finish()
        case "error":
            let error = frame["error"] as? [String: Any]
            lock.lock(); streams[streamId] = nil; lock.unlock()
            continuation.finish(throwing: MuxError.remote(
                code: error?["code"] as? String ?? "unknown",
                message: error?["message"] as? String ?? "stream failed"
            ))
        default:
            break
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let continuations = streams.values
        streams.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.finish(throwing: error) }
    }

    private static func encode(_ frame: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

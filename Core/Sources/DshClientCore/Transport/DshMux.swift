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
            }
            self.failAll(MuxError.closed)
        }
    }

    public func open(endpoint: String, payload: Any = ["args": [String: Any]()]) throws -> AsyncThrowingStream<Any, Error> {
        let streamId = UUID().uuidString
        var captured: AsyncThrowingStream<Any, Error>.Continuation!
        let stream = AsyncThrowingStream<Any, Error> { captured = $0 }
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

    public func cancel(_ stream: AsyncThrowingStream<Any, Error>) {
        // 简化：按流结束通知服务端；当前由 stream 自然结束或关闭连接兜底。
        _ = stream
    }

    /// 断线后重建：旧流一律失败，由调用方重新 open。
    public func reconnect() async throws {
        await close()
        try await connect()
    }

    public func close() async {
        reader?.cancel()
        await ws.close()
        failAll(MuxError.closed)
    }

    private func dispatch(_ text: String) {
        if ProcessInfo.processInfo.environment["DSH_DEBUG"] != nil {
            FileHandle.standardError.write(Data("mux<- \(text.prefix(120))\n".utf8))
        }
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

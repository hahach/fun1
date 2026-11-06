import Foundation
import NIOCore
import NIOPosix

/// 转发器压测：一条连接保持打开，同时在同一条 SSH 会话上开第二条连接。
///
/// 真机上隧道自检的连接有时会被连接池留着（HEAD 的 401 响应带 keep-alive），
/// 随后的凭据请求要另开一条 direct-tcpip 通道。这条路只有「同时存在两条通道」时才暴露，
/// 单连接顺序压测覆盖不到。
public enum ForwardStress {
    public struct Result: Sendable {
        public let rounds: Int
        public let failures: [String]
        public var failed: Bool { !failures.isEmpty }
    }

    /// - Parameters:
    ///   - localPort: 本地转发的监听端口。
    ///   - rounds: 轮数。
    ///   - timeout: 每条连接等响应的上限（秒）。
    public static func run(
        localPort: Int,
        rounds: Int = 10,
        timeout: TimeInterval = 5
    ) async -> Result {
        var failures: [String] = []
        for round in 1...max(1, rounds) {
            do {
                // 第一条：发请求、拿到响应头后**不关闭**，模拟被连接池留住的探针连接。
                let held = try await openConnection(port: localPort, timeout: timeout)
                try await send("HEAD / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n", on: held)
                _ = try await readUntilHeaders(on: held, timeout: timeout)

                // 第二条：同一 SSH 会话上的第二条 direct-tcpip 通道。
                let second = try await openConnection(port: localPort, timeout: timeout)
                try await send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", on: second)
                let status = try await readUntilHeaders(on: second, timeout: timeout)
                if !status.hasPrefix("HTTP/1.") {
                    failures.append("round \(round): unexpected response \(status.prefix(40))")
                }
                try? await second.close().get()
                try? await held.close().get()
            } catch {
                failures.append("round \(round): \(error)")
            }
        }
        return Result(rounds: rounds, failures: failures)
    }

    enum StressError: Error, CustomStringConvertible {
        case connect(String)
        case timeout(String)

        var description: String {
            switch self {
            case .connect(let reason): return "connect: \(reason)"
            case .timeout(let what): return "timeout waiting for \(what)"
            }
        }
    }

    private static func openConnection(port: Int, timeout: TimeInterval) async throws -> Channel {
        do {
            return try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.nanoseconds(Int64(timeout * 1_000_000_000)))
                .connect(host: "127.0.0.1", port: port)
                .get()
        } catch {
            throw StressError.connect("\(error)")
        }
    }

    private static func send(_ text: String, on channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await channel.writeAndFlush(buffer).get()
    }

    private static func readUntilHeaders(on channel: Channel, timeout: TimeInterval) async throws -> String {
        let collector = HeaderCollector()
        try await channel.pipeline.addHandler(collector).get()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = collector.statusLine { return text }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw StressError.timeout("response headers")
    }
}

private final class HeaderCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var buffer = ""
    private var first: String?

    var statusLine: String? {
        lock.lock(); defer { lock.unlock() }
        return first
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        let text = incoming.readString(length: incoming.readableBytes) ?? ""
        lock.lock()
        buffer += text
        if first == nil, let range = buffer.range(of: "\r\n") {
            first = String(buffer[buffer.startIndex..<range.lowerBound])
        }
        lock.unlock()
    }
}

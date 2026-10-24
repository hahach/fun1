import Foundation
import NIOCore
import Crypto
import Citadel

/// 一次 SSH 会话：连接、执行只读命令、关闭。端口转发与传输层在此之上叠加。
public final class SSHClientConnection {
    public enum ConnectionError: Error, Equatable, LocalizedError {
        case notConnected
        case unreachable(host: String, port: Int)
        case refused(host: String, port: Int)
        case timedOut(host: String, port: Int)
        case ssh(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "SSH 尚未连接"
            case .unreachable(let host, let port):
                return "网络到不了 \(host):\(port)：确认手机与主机在同一网络（或已开 VPN），并且主机防火墙放行该端口"
            case .refused(let host, let port):
                return "主机拒绝连接 \(host):\(port)：sshd 未运行或未监听该端口"
            case .timedOut(let host, let port):
                return "连接 \(host):\(port) 超时：检查网络与防火墙"
            case .ssh(let detail):
                return "SSH 失败：\(detail)"
            }
        }
    }

    private let endpoint: Endpoint
    private let key: Curve25519.Signing.PrivateKey
    private let delegate: TOFUHostKeyDelegate
    private var client: SSHClient?

    public init(endpoint: Endpoint, key: Curve25519.Signing.PrivateKey, knownHosts: KnownHosts,
                onHostKey: @escaping @Sendable (TOFUHostKeyDelegate.Decision) -> Void) {
        self.endpoint = endpoint
        self.key = key
        self.delegate = TOFUHostKeyDelegate(known: knownHosts, host: endpoint.host, port: endpoint.port, onDecision: onHostKey)
    }

    /// 连接后返回本次已知主机表（首次连接会多一条）。
    @discardableResult
    public func connect() async throws -> KnownHosts {
        let user = endpoint.user
        let key = self.key
        let settings = SSHClientSettings(
            host: endpoint.host,
            port: endpoint.port,
            authenticationMethod: { .ed25519(username: user, privateKey: key) },
            hostKeyValidator: .custom(self.delegate)
        )
        do {
            client = try await SSHClient.connect(to: settings)
        } catch {
            throw Self.classify(error, host: endpoint.host, port: endpoint.port)
        }
        return delegate.snapshot
    }

    /// 供转发层取底层客户端。
    func sshClient() throws -> SSHClient {
        guard let client else { throw ConnectionError.notConnected }
        return client
    }

    /// 执行命令并取 stdout（命令由调用方给定，本层不拼接 shell 引号）。
    public func run(_ command: String) async throws -> String {
        guard let client else { throw ConnectionError.notConnected }
        let buffer = try await client.executeCommand(command)
        return buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
    }

    public func close() async {
        try? await client?.close()
        client = nil
    }
}


extension SSHClientConnection: CommandRunner {}


extension SSHClientConnection {
    /// 把 NIO/系统错误折成可操作的中文提示。
    static func classify(_ error: Error, host: String, port: Int) -> ConnectionError {
        let text = String(describing: error).lowercased()
        if text.contains("no route to host") { return .unreachable(host: host, port: port) }
        if text.contains("connection refused") { return .refused(host: host, port: port) }
        if text.contains("timed out") || text.contains("timeout") { return .timedOut(host: host, port: port) }
        return .ssh(String(describing: error))
    }
}

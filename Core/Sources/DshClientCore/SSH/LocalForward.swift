import Foundation
import NIOCore
import NIOPosix
import Citadel
import NIOSSH

/// 本地端口转发：监听 127.0.0.1:<随机端口>，每条连接经 SSH 开一条 direct-tcpip 到目标地址。
public final class LocalForwarder: @unchecked Sendable {
    public enum ForwardError: Error, Equatable {
        case noLocalPort
    }

    private let group: EventLoopGroup
    private let lock = NSLock()
    private var server: Channel?

    public init(group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
    }

    /// 返回实际监听的本地端口。
    public func start(client: SSHClient, targetHost: String = "127.0.0.1", targetPort: Int = 3080) async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { local in
                self.bridge(local: local, client: client, host: targetHost, port: targetPort)
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        lock.lock(); server = channel; lock.unlock()
        guard let port = channel.localAddress?.port else { throw ForwardError.noLocalPort }
        return port
    }

    public func stop() async {
        lock.lock()
        let channel = server
        server = nil
        lock.unlock()
        try? await channel?.close().get()
    }

    private func bridge(local: Channel, client: SSHClient, host: String, port: Int) -> EventLoopFuture<Void> {
        let promise = local.eventLoop.makePromise(of: Void.self)
        Task {
            do {
                let settings = try SSHChannelType.DirectTCPIP(
                    targetHost: host,
                    targetPort: port,
                    originatorAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0)
                )
                let remote = try await client.createDirectTCPIPChannel(using: settings) { _ in
                    local.eventLoop.makeSucceededFuture(())
                }
                try await local.pipeline.addHandler(Relay(peer: remote)).get()
                try await remote.pipeline.addHandler(Relay(peer: local)).get()
                promise.succeed(())
            } catch {
                local.close(promise: nil)
                promise.fail(error)
            }
        }
        return promise.futureResult
    }
}

/// 把一侧的字节原样写给另一侧；任一侧关闭即关另一侧。
private final class Relay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(data, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }
}

import Crypto
import Foundation
import NIOCore
import NIOPosix
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 最小 WebSocket 客户端：只做文本帧、ping/pong、close。
///
/// 不用 URLSessionWebSocketTask，是因为它要请求某个具体 URL；我们的连接在隧道里，
/// 而且 Linux 探针必须与 iOS 走同一份实现。
public final class WebSocketClient: @unchecked Sendable {
    public enum WSError: Error, Equatable {
        case handshakeRejected(status: Int)
        case badAccept
        case closed
        case notConnected
    }

    /// 收到任何帧（文本、Ping、Pong）时回调，供上层判断"对端还活着"。
    /// 服务端每 2 秒发一次 Ping，这条信号比业务数据稳定得多。
    public var onActivity: (@Sendable () -> Void)?

    private let group: EventLoopGroup
    private var channel: Channel?
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    public private(set) var incoming: AsyncThrowingStream<String, Error>!

    public init(group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
        var captured: AsyncThrowingStream<String, Error>.Continuation!
        incoming = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    public struct Handshake {
        public let host: String
        public let port: Int
        public let path: String
        public let cookie: String?
        public init(host: String, port: Int, path: String = "/api/remote.mux", cookie: String? = nil) {
            self.host = host
            self.port = port
            self.path = path
            self.cookie = cookie
        }
    }

    public func connect(_ handshake: Handshake) async throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let handshakePromise = group.next().makePromise(of: Void.self)
        let handler = HandshakeHandler(handshake: handshake, key: key,
            handshakePromise: handshakePromise,
            onOpen: { [weak self] channel in self?.channel = channel },
            onActivity: { [weak self] in self?.onActivity?() },
            onText: { [weak self] text in self?.continuation?.yield(text) },
            onClose: { [weak self] error in
                if let error { self?.continuation?.finish(throwing: error) } else { self?.continuation?.finish() }
            })

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
        let channel = try await bootstrap.connect(host: handshake.host, port: handshake.port).get()
        try await handshakePromise.futureResult.get()
        self.channel = channel
    }

    public func send(_ text: String) async throws {
        guard let channel else { throw WSError.notConnected }
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        let frame = WebSocketFrame.encode(opcode: 0x1, payload: buffer)
        try await channel.writeAndFlush(frame).get()
    }

    public func close() async {
        if let channel {
            let frame = WebSocketFrame.encode(opcode: 0x8, payload: ByteBuffer())
            _ = try? await channel.writeAndFlush(frame).get()
            try? await channel.close().get()
        }
        channel = nil
        continuation?.finish()
    }
}

/// 握手 + 帧解析。握手完成后本 handler 常驻，把文本帧交给上层。
final class HandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let handshake: WebSocketClient.Handshake
    private let key: String
    /// 期望的 Sec-WebSocket-Accept 值：base64(SHA1(key + RFC 6455 魔串))。
    private let expectedAccept: String
    private let handshakePromise: EventLoopPromise<Void>
    private let onOpen: (Channel) -> Void
    private let onText: (String) -> Void
    private let onClose: (Error?) -> Void

    private var handshakeBuffer = ByteBuffer()
    private var frameBuffer = ByteBuffer()
    private var didHandshake = false
    private var fragment = ByteBuffer()
    private let onActivity: () -> Void

    init(handshake: WebSocketClient.Handshake, key: String,
         handshakePromise: EventLoopPromise<Void>,
         onOpen: @escaping (Channel) -> Void,
         onActivity: @escaping () -> Void,
         onText: @escaping (String) -> Void,
         onClose: @escaping (Error?) -> Void) {
        self.handshake = handshake
        self.key = key
        // RFC 6455 §4.2.2：Accept 必须验值，只查头存在挡不住错误/伪造的握手。
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        self.expectedAccept = Data(digest).base64EncodedString()
        self.handshakePromise = handshakePromise
        self.onOpen = onOpen
        self.onActivity = onActivity
        self.onText = onText
        self.onClose = onClose
    }

    func channelActive(context: ChannelHandlerContext) {
        var request = "GET \(handshake.path) HTTP/1.1\r\n"
        request += "Host: \(handshake.host):\(handshake.port)\r\n"
        request += "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        if let cookie = handshake.cookie { request += "Cookie: \(cookie)\r\n" }
        request += "\r\n"
        var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = self.unwrapInboundIn(data)
        // 握手完成后任何字节都算对端活动：Ping 也是帧，链路活着就不会有长静默。
        if didHandshake { onActivity() }
        if ProcessInfo.processInfo.environment["DSH_DEBUG"] != nil {
            FileHandle.standardError.write(Data("ws bytes=\(incoming.readableBytes) handshook=\(didHandshake)\n".utf8))
        }
        if !didHandshake {
            handshakeBuffer.writeBuffer(&incoming)
            // 按字节找 "\r\n\r\n"：Swift 把 CRLF 当一个 Character，用 String 的 distance
            // 得到的偏移会少于字节数，帧就会从错位处解析。
            let bytes = Array(handshakeBuffer.readableBytesView)
            guard let end = Self.headerEnd(in: bytes) else { return }
            let head = String(decoding: bytes[0..<(end - 4)], as: UTF8.self)
            let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
            guard status == 101 else {
                handshakePromise.fail(WebSocketClient.WSError.handshakeRejected(status: status))
                onClose(WebSocketClient.WSError.handshakeRejected(status: status))
                context.close(promise: nil)
                return
            }
            guard Self.headerValue(of: "sec-websocket-accept", in: head) == expectedAccept else {
                handshakePromise.fail(WebSocketClient.WSError.badAccept)
                onClose(WebSocketClient.WSError.badAccept)
                context.close(promise: nil)
                return
            }
            handshakePromise.succeed(())
            didHandshake = true
            onOpen(context.channel)
            let consumed = end
            let leftover = handshakeBuffer.readableBytes - consumed
            incoming = leftover > 0 ? (handshakeBuffer.getSlice(at: consumed, length: leftover) ?? ByteBuffer()) : ByteBuffer()
            handshakeBuffer.clear()
        }
        frameBuffer.writeBuffer(&incoming)
        if ProcessInfo.processInfo.environment["DSH_DEBUG"] != nil {
            FileHandle.standardError.write(Data("ws frameBuffer=\(frameBuffer.readableBytes)\n".utf8))
        }
        decodeFrames(context: context)
    }

    /// 返回头部结束位置（含结尾的四个字节），找不到返回 nil。
    static func headerEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index + 4
        }
        return nil
    }

    /// 大小写不敏感地取一条响应头的值；按换行切头（行尾的 \r 一并去掉），首行状态行跳过。
    static func headerValue(of name: String, in head: String) -> String? {
        for line in head.split(whereSeparator: \.isNewline).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func decodeFrames(context: ChannelHandlerContext) {
        while let frame = WebSocketFrame.decode(&frameBuffer) {
            switch frame.opcode {
            case 0x1, 0x0:
                fragment.writeImmutableBuffer(frame.payload)
                if frame.fin {
                    let text = fragment.getString(at: 0, length: fragment.readableBytes) ?? ""
                    fragment.clear()
                    if ProcessInfo.processInfo.environment["DSH_DEBUG"] != nil {
                        FileHandle.standardError.write(Data("ws<- \(text.prefix(80))\n".utf8))
                    }
                    onText(text)
                }
            case 0x8:
                onClose(nil)
                context.close(promise: nil)
            case 0x9:
                let pong = WebSocketFrame.encode(opcode: 0xA, payload: frame.payload)
                context.writeAndFlush(NIOAny(pong), promise: nil)
            default:
                break
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // 握手前断线（例如对端 401 后直接断开）必须让等待方失败，否则 connect 永远挂住。
        if !didHandshake { handshakePromise.fail(WebSocketClient.WSError.closed) }
        onClose(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !didHandshake { handshakePromise.fail(error) }
        onClose(error)
        context.close(promise: nil)
    }
}

struct WebSocketFrame {
    let fin: Bool
    let opcode: UInt8
    let payload: ByteBuffer

    /// 客户端发出的帧必须加掩码。
    static func encode(opcode: UInt8, payload: ByteBuffer) -> ByteBuffer {
        var out = ByteBuffer()
        out.writeInteger(UInt8(0x80 | opcode))
        let length = payload.readableBytes
        let mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
        if length < 126 {
            out.writeInteger(UInt8(0x80 | UInt8(length)))
        } else if length <= 0xFFFF {
            out.writeInteger(UInt8(0x80 | 126))
            out.writeInteger(UInt16(length))
        } else {
            out.writeInteger(UInt8(0x80 | 127))
            out.writeInteger(UInt64(length))
        }
        out.writeBytes(mask)
        var bytes = [UInt8](payload.readableBytesView)
        for index in bytes.indices { bytes[index] ^= mask[index % 4] }
        out.writeBytes(bytes)
        return out
    }

    static func decode(_ buffer: inout ByteBuffer) -> WebSocketFrame? {
        guard buffer.readableBytes >= 2 else { return nil }
        guard let first: UInt8 = buffer.getInteger(at: buffer.readerIndex),
              let second: UInt8 = buffer.getInteger(at: buffer.readerIndex + 1) else { return nil }
        let fin = (first & 0x80) != 0
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.readableBytes >= 4, let value: UInt16 = buffer.getInteger(at: buffer.readerIndex + 2) else { return nil }
            length = Int(value); offset = 4
        } else if length == 127 {
            guard buffer.readableBytes >= 10, let value: UInt64 = buffer.getInteger(at: buffer.readerIndex + 2) else { return nil }
            length = Int(value); offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard buffer.readableBytes >= offset + 4 else { return nil }
            mask = (0..<4).compactMap { buffer.getInteger(at: buffer.readerIndex + offset + $0) }
            offset += 4
        }
        guard buffer.readableBytes >= offset + length else { return nil }
        var payload = buffer.getSlice(at: buffer.readerIndex + offset, length: length) ?? ByteBuffer()
        if masked {
            var bytes = [UInt8](payload.readableBytesView)
            for index in bytes.indices { bytes[index] ^= mask[index % 4] }
            payload.clear()
            payload.writeBytes(bytes)
        }
        buffer.moveReaderIndex(forwardBy: offset + length)
        return WebSocketFrame(fin: fin, opcode: opcode, payload: payload)
    }
}

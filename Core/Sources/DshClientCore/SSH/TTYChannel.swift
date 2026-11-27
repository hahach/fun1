import Foundation
import NIOCore
import NIOSSH
import Citadel

/// 一条交互式 shell：与 dsh 会话共用同一个 SSH 客户端。
///
/// 输出按字节流交给调用方（终端组件自己解析 ANSI）；输入与窗口尺寸变更走
/// Citadel 的 `TTYStdinWriter`。
public final class TTYChannel: @unchecked Sendable {
    public enum TTYError: Error, Equatable {
        case closed
    }

    public let output: AsyncThrowingStream<Data, Error>

    private let writer: TTYStdinWriter
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var closed = false

    init(writer: TTYStdinWriter, outputContinuation: AsyncThrowingStream<Data, Error>.Continuation, output: AsyncThrowingStream<Data, Error>) {
        self.writer = writer
        self.outputContinuation = outputContinuation
        self.output = output
    }

    public func send(_ bytes: [UInt8]) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await writer.write(buffer)
    }

    public func send(_ text: String) async throws {
        try await send(Array(text.utf8))
    }

    public func resize(cols: Int, rows: Int) async {
        try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    public func close() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        guard !already else { return }
        outputContinuation.finish()
    }
}

extension SSHClientConnection {
    /// 开一个 100×30 的 PTY 交互 shell。调用方负责 `close()`。
    public func openTTY(cols: Int = 100, rows: Int = 30) async throws -> TTYChannel {
        let client = try sshClient()
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        let (outputStream, outputContinuation) = AsyncThrowingStream<Data, Error>.makeStream()

        let writerPromise = Deferred<TTYStdinWriter>()

        Task {
            do {
                try await client.withPTY(request) { inbound, outbound in
                    writerPromise.resolve(outbound)
                    do {
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                outputContinuation.yield(Data(buffer.readableBytesView))
                            }
                        }
                    } catch {
                        outputContinuation.finish(throwing: error)
                        return
                    }
                    // shell 自己退出（敲 exit、.bashrc 退出、断链）时立即结束输出流，
                    // 否则上层的 for try await 永远等不到流结束。
                    outputContinuation.finish()
                }
                outputContinuation.finish()
            } catch {
                writerPromise.fail(error)
                outputContinuation.finish(throwing: error)
            }
        }

        let writer = try await writerPromise.value()
        return TTYChannel(writer: writer, outputContinuation: outputContinuation, output: outputStream)
    }
}

/// 把「闭包内产出、闭包外等待」的那一步包起来。
private final class Deferred<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiter: CheckedContinuation<Value, Error>?

    func resolve(_ value: Value) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: value)
            return
        }
        result = .success(value)
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(throwing: error)
            return
        }
        result = .failure(error)
        lock.unlock()
    }

    func value() async throws -> Value {
        lock.lock()
        if let result {
            lock.unlock()
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            lock.unlock()
        }
    }
}

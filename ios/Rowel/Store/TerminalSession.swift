import Foundation
import DshClientCore

/// 终端会话：把 PTY 通道从视图生命周期里摘出来。
///
/// 离开终端页不关 shell；回来后把留存的最近输出重放一遍，屏幕不是空白。
/// SSH 连接已被系统掐断（后台挂起后常见）时，先让传输层整栈重建再重开一次。
@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var errorText: String?

    /// 重放给新视图的最大字节数。
    private static let scrollbackLimit = 200_000

    private let transport: DshTransport
    private var channel: TTYChannel?
    private var pump: Task<Void, Never>?
    private var scrollback: [UInt8] = []
    private var cols = 100
    private var rows = 30
    /// 视图挂上时设置，卸下时清空；输出继续留在 `scrollback` 里。
    private var sink: ((ArraySlice<UInt8>) -> Void)?

    init(transport: DshTransport) {
        self.transport = transport
    }

    /// 打开 PTY；失败时先整栈重建传输层再试一次。
    func openIfNeeded() async {
        guard channel == nil else { return }
        await open()
    }

    private func open() async {
        errorText = nil
        do {
            channel = try await transport.dshSession.openTTY(cols: cols, rows: rows)
        } catch {
            do {
                try await transport.refresh()
                channel = try await transport.dshSession.openTTY(cols: cols, rows: rows)
            } catch {
                errorText = DshBoard.message(error)
                Diagnostics.shared.log(.fail, "终端", errorText ?? "")
                return
            }
        }
        isOpen = true
        startPump()
    }

    /// 重开一条 PTY：shell 退出、或换过字号/尺寸之后用。
    func reopen() async {
        pump?.cancel()
        pump = nil
        channel?.close()
        channel = nil
        isOpen = false
        errorText = nil
        scrollback.removeAll()
        // 先把「重开中」画出来，再去重建：否则会闪一帧旧错误页。
        await Task.yield()
        // shell 自己退出时，旧 PTY 可能把底层通道留在半关状态：先整栈重建再开，
        // 否则第二次 withPTY 会一直失败，表现成「点了没反应」。
        try? await transport.refresh()
        await open()
    }

    func send(_ bytes: [UInt8]) {
        guard let channel else { return }
        Task { try? await channel.send(bytes) }
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        guard let channel else { return }
        cols = newCols
        rows = newRows
        Task { await channel.resize(cols: newCols, rows: newRows) }
    }

    /// 新视图挂上：接上输出并重放留存内容。
    func attach(sink: @escaping (ArraySlice<UInt8>) -> Void) {
        self.sink = sink
        guard !scrollback.isEmpty else { return }
        sink(ArraySlice(scrollback))
    }

    func detach() {
        sink = nil
    }

    private func startPump() {
        guard let channel else { return }
        pump?.cancel()
        pump = Task { [weak self] in
            do {
                for try await data in channel.output {
                    guard let self else { return }
                    self.append([UInt8](data))
                }
            } catch {
                // shell 退出或连接断开：状态归零，下次进页面重开。
            }
            guard let self else { return }
            self.channel = nil
            self.isOpen = false
            if self.errorText == nil { self.errorText = "终端会话已结束，点重试再打开" }
        }
    }

    private func append(_ bytes: [UInt8]) {
        scrollback.append(contentsOf: bytes)
        if scrollback.count > Self.scrollbackLimit {
            scrollback.removeFirst(scrollback.count - Self.scrollbackLimit)
        }
        sink?(ArraySlice(bytes))
    }
}


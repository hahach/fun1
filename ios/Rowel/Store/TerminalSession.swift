import Foundation
import DshClientCore

/// 终端会话：把 PTY 通道从视图生命周期里摘出来。
///
/// 离开终端页不关 shell；回来后把留存的最近输出重放一遍，屏幕不是空白。
/// SSH 连接已被系统掐断（后台挂起后常见）时，先让调用方把连接弄回来再重开一次。
///
/// **与传输层解耦**：开通道与「自救一次」都由调用方注入两个闭包，本类只管通道、
/// 输出与回放。同一条终端因此有两个宿主：
/// - 会话页（dsh 就绪）：`transport.dshSession.openShell` + `transport.refresh`——
///   打开失败时整栈重建传输层，与改造前一致；
/// - 连接页的降级态（SSH 已连、dsh 未就绪）：`session.openShell` + `session.retryDsh`——
///   复用同一条 SSH 重试 dsh，不动连接（shell 就是用来把 dsh 救回来的）。
@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var errorText: String?

    /// 重放给新视图的最大字节数。
    private static let scrollbackLimit = 200_000

    /// 开一条 PTY（列数、行数由终端页给）。
    private let open: @Sendable (Int, Int) async throws -> TTYChannel
    /// 打开失败时的自救：只负责把连接弄回来，不负责开通道（本类随后再开一次）。
    private let retry: @Sendable () async throws -> Void
    private var channel: TTYChannel?
    private var pump: Task<Void, Never>?
    /// 正在开 PTY：连点「重开」或 .task 与场景回调同时进来时，只放一条过去。
    private var opening = false
    private var scrollback: [UInt8] = []
    private var cols = 100
    private var rows = 30
    /// 视图挂上时设置，卸下时清空；输出继续留在 `scrollback` 里。
    private var sink: ((ArraySlice<UInt8>) -> Void)?

    init(
        open: @escaping @Sendable (Int, Int) async throws -> TTYChannel,
        retry: @escaping @Sendable () async throws -> Void
    ) {
        self.open = open
        self.retry = retry
    }

    /// 打开 PTY；失败时先 `retry`（把连接弄回来）再试一次。
    func openIfNeeded() async {
        guard channel == nil else { return }
        await openChannel()
    }

    private func openChannel() async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        errorText = nil
        do {
            adopt(try await open(cols, rows))
        } catch {
            do {
                try await retry()
                adopt(try await open(cols, rows))
            } catch {
                errorText = DshBoard.message(error)
                Diagnostics.shared.log(.fail, "终端", errorText ?? "")
                return
            }
        }
        isOpen = true
        startPump()
    }

    /// 接上新通道：旧通道先关，别留下一条没人 pump 的 PTY。
    private func adopt(_ fresh: TTYChannel) {
        channel?.close()
        channel = fresh
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
        // shell 自己退出时，旧 PTY 可能把底层通道留在半关状态：先让调用方把连接
        // 弄回来再开，否则第二次开 PTY 会一直失败，表现成「点了没反应」。
        try? await retry()
        await openChannel()
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
        // 攒到 1.25 倍上限才裁一次：繁忙 shell 下每片输出都整体搬移 200 KB 是白烧。
        if scrollback.count > Self.scrollbackLimit * 5 / 4 {
            scrollback.removeFirst(scrollback.count - Self.scrollbackLimit)
        }
        sink?(ArraySlice(bytes))
    }
}

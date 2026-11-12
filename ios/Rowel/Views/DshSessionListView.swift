import SwiftUI

/// 连上之后的第一屏：按工作区分组的会话列表，待批准事项上浮。
///
/// 分组与归档规则复用上游的 `SessionBoard`（纯逻辑）：子代理不占列表行（它们挂在
/// 父会话里），归档会话不进主列表，等答案的会话提到最前面。
struct DshSessionListView: View {
    let transport: DshTransport

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var board: DshBoard
    @State private var creating = false
    /// 刚新建的会话：建完直接进去，别让人在列表里找那条空白会话。
    @State private var justCreatedId: String?
    /// 刚建那条的目录：列表还没刷新时用它现造摘要（不往 sessions 里塞）。
    @State private var justCreatedCwd: String?
    @State private var query = ""
    @State private var renaming: SessionSummary?
    @ObservedObject private var readState = ReadState.shared

    init(transport: DshTransport) {
        self.transport = transport
        _board = StateObject(wrappedValue: DshBoard(transport: transport))
    }

    var body: some View {
        List {
            if board.link != .ok {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: board.link == .offline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                        Text(board.link == .offline ? "网络不可用，恢复后自动重连" : "连接已断开，正在重连…")
                        Spacer()
                        if board.link != .offline {
                            Button("立即重连") { Task { await refreshAll() } }
                                .font(.caption)
                                .buttonStyle(.borderless)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.warn)
                }
            }

            if let errorText = board.errorText {
                Section {
                    Text(errorText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if !board.pending.isEmpty || !board.questions.isEmpty {
                Section("等你决定") {
                    ForEach(board.pending) { approval in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title(for: approval.sessionId))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ApprovalCard(request: approval) { allow in
                                Task { await board.answer(approval, allow: allow) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(board.questions) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title(for: question.sessionId))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            QuestionCard(request: question) { answers in
                                Task { await board.answer(question, answers: answers) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            let pinnedShown = board.pinnedSessions.filter(matches)
            if !pinnedShown.isEmpty {
                Section("置顶") {
                    ForEach(pinnedShown) { session in
                        row(session)
                    }
                }
            }

            ForEach(shownGroups) { group in
                Section(group.title) {
                    ForEach(group.sessions) { session in
                        row(session)
                    }
                }
            }

            Section {
                NavigationLink {
                    DshArchiveListView(board: board)
                } label: {
                    Label("归档（\(board.archivedSessions.count)）", systemImage: "archivebox")
                        .font(.callout)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Text(board.refreshedAt.map { "已刷新 · \(Self.clock.string(from: $0))" } ?? "下拉可刷新并重连")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $creating) {
            DshNewSessionView(transport: transport, board: board) { id, cwd in
                creating = false
                justCreatedCwd = cwd
                justCreatedId = id
            }
        }
        .searchable(text: $query, prompt: "按标题或目录筛选")
        .refreshable { await refreshAll() }
        .task {
            board.startEvents()
            await loadAll()
        }
        .onChange(of: scenePhase) { _, phase in
            // 回前台：连接多半已死，重读一次（失败时 board 自己会重建）。
            if phase == .active {
                board.restartWorkspaces()
                Task { await loadAll() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    DshSettingsView(transport: transport, board: board)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(item: $justCreatedId) { id in
            if let session = board.sessions.first(where: { $0.id == id })
                ?? board.blankSummary(id, cwd: justCreatedCwd) {
                DshConversationView(transport: transport, summary: session, board: board)
            }
        }
        .sheet(item: $renaming) { session in
            DshRenameSheet(session: session) { title in
                Task { await commitRename(session, title: title) }
            }
        }
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 固定时间戳：`relative` 会每分钟重算，读起来像「还在进行」。
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private func row(_ session: SessionSummary) -> some View {
        NavigationLink {
            DshConversationView(transport: transport, summary: session, board: board)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.body)
                HStack(spacing: 8) {
                    if session.running {
                        Text("运行中").font(.caption2).foregroundStyle(.green)
                    } else if readState.isUnread(session) {
                        Text("未读").font(.caption2).foregroundStyle(.blue)
                    }
                    Text(Self.stamp.string(from: session.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // 只滑出按钮、不靠全滑直接执行：归档不是有损动作，但误触仍然讨嫌。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("归档") { Task { await board.archive(session.id) } }
                .tint(.orange)
        }
        .contextMenu {
            if board.pinned.contains(session.id) {
                Button("取消置顶") { Task { await board.unpin(session.id) } }
            } else {
                Button("置顶") { Task { await board.pin(session.id) } }
            }
            Button("重命名") {
                renaming = session
            }
            Button("另起一支") { Task { await fork(session.id) } }
        }
    }

    /// 待批准事项的标题：子代理会话也一起查，查不到就明说。
    private func title(for sessionId: String) -> String {
        guard let match = board.sessions.first(where: { $0.id == sessionId }) else { return "未知会话" }
        return match.isSubagent ? "子代理 · \(match.displayTitle)" : match.displayTitle
    }

    /// 本地按标题与目录筛选：桌面侧栏的搜索也是这个做法。
    ///
    /// dsh 另有 `session/search`（正文检索、带片段），但那要主机配 session-query 索引，
    /// 没有时整个调用被拒；这里不拿它当主路径。
    private var needle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ session: SessionSummary) -> Bool {
        guard !needle.isEmpty else { return true }
        if session.displayTitle.lowercased().contains(needle) { return true }
        if let cwd = session.cwd, cwd.lowercased().contains(needle) { return true }
        return false
    }

    /// 分组按筛选结果重算：空组不画 header。
    private var shownGroups: [DshGroup] {
        board.groups.compactMap { group in
            let kept = group.sessions.filter(matches)
            return kept.isEmpty ? nil : DshGroup(id: group.id, title: group.title, sessions: kept)
        }
    }

    /// 从这条会话分叉：机器把历史复制到一条新会话，返回新 id。
    private func fork(_ sessionId: String) async {
        do {
            let harness = Harness(transport: transport)
            let made = try await harness.fork(sessionId: sessionId)
            // 分支默认沿用同名会分不清：给新会话加个后缀（失败不影响分支本身）。
            let base = board.sessions.first { $0.id == sessionId }?.displayTitle ?? "会话"
            try? await harness.rename(sessionId: made, title: base + " · 分支")
            await loadAll()
            justCreatedId = made
        } catch {
            board.report(error)
        }
    }

    private func commitRename(_ target: SessionSummary, title: String) async {
        guard !title.isEmpty else { return }
        Diagnostics.shared.log(.info, "改名", "请求：\(target.id) → \(title)")
        do {
            try await Harness(transport: transport).rename(sessionId: target.id, title: title)
            board.applyTitle(title, to: target.id)
            Diagnostics.shared.log(.info, "改名", "成功")
            await board.load()
        } catch {
            Diagnostics.shared.log(.fail, "改名", DshBoard.message(error))
            board.report(error)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 下拉刷新：**先真重连一次**再重读列表。长流半死时 RPC 还能通，只重读列表
    /// 看不出任何区别，人会以为刷新没生效（B-152）。
    private func refreshAll() async {
        board.restartWorkspaces()
        do {
            try await transport.refresh(trigger: "列表下拉刷新")
            board.clearError()
        } catch {
            board.report(error)
        }
        await loadAll()
        Diagnostics.shared.log(.info, "列表", "下拉刷新完成（链接 \(board.link)）")
    }

    private func loadAll() async {
        board.startWorkspaces()
        await board.load()
    }

}
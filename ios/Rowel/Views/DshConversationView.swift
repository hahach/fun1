import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// 会话详情：跟随一条会话、显示历史、发一条消息。
///
/// 事件折叠复用上游的 `Conversation`（它已按 dsh 0.2 的帧格式写好），
/// 这里只负责开流、把三类帧喂进去、以及把输入框接到 `session/prompt`。
struct DshConversationView: View {
    let transport: DshTransport
    let summary: SessionSummary
    @ObservedObject var board: DshBoard
    /// 子代理会话要靠父会话寻址，dsh 才肯读它自己的日志。
    let parent: SubagentParent?
    @Environment(\.scenePhase) private var scenePhase

    @State private var conversation: Conversation
    @State private var draft = ""
    @State private var errorText: String?
    @State private var pumping: Task<Void, Never>?
    @State private var needsReconnect = false
    @State private var terminal: TerminalSession?
    /// 列表滚动代理：翻页时在同一个事务里把锚点钉回去，界面不会跳。
    @State private var scrollProxy: ScrollViewProxy?
    /// 这次条数变化是翻页插进来的，不该滚到底。
    @State private var pagingInsert = false
    @State private var showingTrace = false
    /// 本页看到的运行状态：发送即真，`turn/end` 即假。
    @State private var runningNow = false
    /// 正在编辑的待发消息。
    @State private var editingQueued: QueuedMessage?
    /// 待发送的图片（base64 直接进 prompt，不需要上传）。
    @State private var attachments: [PendingImage] = []
    @State private var pickedItem: PhotosPickerItem?
    /// 从 md 链接点开的文件。
    @State private var previewPath: String?
    /// 翻页时钉住的可见首条（`scrollPosition` 的绑定）。
    @State private var topItemId: String?
    /// `/` 之后的候选：技能（文本）与命令（机器执行）两类合在一起。
    @State private var slash: [SlashCommand] = []
    @State private var slashLoading = false
    /// 命令执行后的一行提示：dsh 只回值，界面上原来什么也看不到。
    @State private var notice: String?
    /// 输入框上方那排工具要的数据：模型目录与权限预设。
    @State private var models: ModelCatalog?
    @State private var permissionOptions: [PermissionChoice.Option] = []

    private static let bottomAnchor = "dsh.bottom"

    init(transport: DshTransport, summary: SessionSummary, board: DshBoard, parent: SubagentParent? = nil) {
        self.transport = transport
        self.summary = summary
        _board = ObservedObject(wrappedValue: board)
        self.parent = parent
        _conversation = State(initialValue: Conversation(
            sessionId: summary.id,
            title: summary.title,
            cwd: summary.cwd
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if needsReconnect {
                Button {
                    Task { await reconnect() }
                } label: {
                    Label("连接已中断，点此重连", systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
            }

            ForEach(board.approvals(for: summary.id)) { approval in
                ApprovalCard(request: approval) { allow in
                    Task { await board.answer(approval, allow: allow) }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
            }

            ForEach(board.questions(for: summary.id)) { question in
                QuestionCard(request: question) { answers in
                    Task { await board.answer(question, answers: answers) }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
            }

            childrenBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.gap) {
                    if conversation.hasMore {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            Text(conversation.loading ? "加载中…" : "加载更早的消息")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    ForEach(conversation.items) { item in
                        TranscriptItem(item: item)
                            .id(item.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    if conversation.loading {
                        Text("加载中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.gap)
                }
                .scrollTargetLayout()
                .scrollPosition(id: $topItemId, anchor: .top)
                .onAppear {
                    attach(proxy)
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                .onChange(of: conversation.loaded) { _, loaded in
                    if loaded { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
                .onChange(of: conversation.items.count) { _, _ in
                    ReadState.shared.markRead(summary.id)
                    // 翻页插进来的条数变化自己钉位置，别再把视图拽到底部。
                    guard !pagingInsert else {
                        pagingInsert = false
                        return
                    }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }

            if let filter = slashFilter {
                CommandPicker(commands: slash, filter: filter) { picked in
                    Task { await run(picked) }
                }
            }

            if !conversation.todos.isEmpty {
                TodoStrip(todos: conversation.todos)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 6)
            }

            if !attachments.isEmpty {
                attachmentStrip
            }

            if !conversation.queue.isEmpty {
                DshQueuedBar(items: conversation.queue) { item in
                    editingQueued = item
                } onRemove: { item in
                    Task { await removeQueued(item) }
                } onSteer: { item in
                    Task { await steerQueued(item) }
                }
            }

            composerTools

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 4)
            }

            Divider()

            HStack(spacing: 8) {
                TextField(conversation.planning ? "计划模式：先说怎么做…" : "发消息…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                Button(isBusy ? "排队" : "发送") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
            }
            .padding(12)

            statusStrip
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingTrace = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let terminal {
                    NavigationLink {
                        DshTerminalScreen(session: terminal)
                    } label: {
                        Image(systemName: "terminal")
                    }
                }
            }
        }
        .navigationTitle(summary.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            ReadState.shared.markRead(summary.id)
            if terminal == nil { terminal = TerminalSession(transport: transport) }
            conversation.loading = true
            board.startEvents()
            startFollowing()
            await loadSlash()
            await loadTools()
        }
        .onDisappear { stopFollowing() }
        .sheet(item: $editingQueued) { item in
            DshTextEditSheet(title: "编辑待发消息", initial: item.text) { text in
                Task { await saveQueuedEdit(item, text: text) }
            }
        }
        .sheet(isPresented: Binding(
            get: { previewPath != nil },
            set: { if !$0 { previewPath = nil } }
        )) {
            if let previewPath {
                DshFilePreviewView(transport: transport, path: previewPath)
            }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let path = Self.localPath(from: url) {
                previewPath = path
                return .handled
            }
            return .systemAction
        })
        .sheet(isPresented: $showingTrace) {
            DshTraceView(conversation: conversation) { itemId in
                withTransaction(Transaction(animation: nil)) {
                    scrollProxy?.scrollTo(itemId, anchor: .center)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 回前台自动重连：后台挂起会掐断 SSH，用户不必再手点一次。
            if phase == .active, needsReconnect {
                Task { await reconnect() }
            }
        }
    }

    private func reconnect() async {
        needsReconnect = false
        do {
            try await transport.refresh()
            errorText = nil
            board.startEvents()
            board.restartWorkspaces()
            startFollowing()
        } catch {
            errorText = DshBoard.message(error)
            needsReconnect = true
        }
    }

    /// 跟随流：会话开着就一直开。审批不在本视图收，`board` 的 `$events` 统一管，
    /// 这样停在列表页也能看到并作答。
    private func startFollowing() {
        stopFollowing()
        pumping = Task { await pump() }
    }

    private func stopFollowing() {
        pumping?.cancel()
        pumping = nil
    }

    /// 往前翻一页。窗口可能在翻页途中被快照替换，那这一页就丢掉。
    private func loadOlder() async {
        guard conversation.hasMore, let before = conversation.oldestSeq, let through = conversation.cursor,
              !conversation.loading else { return }
        let generation = conversation.generation
        // 翻页前的那条消息：插入后滚回它的顶部，阅读位置原地不动。
        let anchor = conversation.items.first?.id
        conversation.loading = true
        defer { if conversation.generation == generation { conversation.loading = false } }
        do {
            let page = try await Harness(transport: transport).page(
                sessionId: summary.id,
                parent: parent,
                throughSeq: through,
                beforeSeq: before,
                maxMessages: 25
            )
            guard conversation.generation == generation else { return }
            // 同一个事务里插入并滚回锚点：分两次做会看到文字整体位移一下。
            pagingInsert = true
            // 让滚动位置以「当前可见首条」为准：插入后它仍被钉在顶部，界面不位移。
            if let anchor { topItemId = anchor }
            conversation.absorb(page: page)
        } catch {
            errorText = DshBoard.message(error)
        }
    }

    /// 子代理只放一个入口行：一次开了二十个子代理的会话，逐行铺开会把正文挤没。
    private var childrenBar: some View {
        let children = board.children(of: summary.id)
        return Group {
            if !children.isEmpty {
                NavigationLink {
                    DshSubagentListView(transport: transport, board: board, parent: summary)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                        Text("子代理 \(children.count)")
                            .font(.footnote)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// 把 ScrollViewReader 给的代理留下：翻页时要在同一个事务里用它。
    private func attach(_ proxy: ScrollViewProxy) {
        if scrollProxy == nil { scrollProxy = proxy }
    }

    private func pump() async {
        let task = Task {
            let harness = Harness(transport: transport)
            let stream = await harness.follow(sessionId: summary.id, parent: parent, maxMessages: 25)
            do {
                for try await item in stream.items {
                    receive(item)
                }
            } catch {
                errorText = DshBoard.message(error)
                needsReconnect = true
            }
        }
        pumping = task
        await task.value
    }

    private func receive(_ item: JSONValue) {
        switch item["type"]?.stringValue {
        case "snapshot":
            conversation.adopt(snapshot: item)
            conversation.loading = false
        case "event":
            if let event = item["event"] {
                if event["type"]?.stringValue == "turn/end" {
                    runningNow = false
                    Task { await board.load() }
                }
                conversation.apply(event: event)
            }
        case "assistant-stream":
            if let frame = item["frame"] { conversation.receiveStream(frame) }
        default:
            break
        }
    }

    /// 输入框上方那排：附件（占位）、权限模式、模型，最右是停止。
    private var composerTools: some View {
        let live = board.sessions.first { $0.id == summary.id }
        return HStack(spacing: 14) {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Image(systemName: attachments.isEmpty ? "photo" : "photo.fill")
                    .foregroundStyle(attachments.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)

            Menu {
                if permissionOptions.isEmpty {
                    Text("权限预设未载入")
                }
                ForEach(permissionOptions) { option in
                    Button {
                        Task { await switchPermission(to: option.value) }
                    } label: {
                        if option.value == live?.permission {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            } label: {
                Text(permissionName(for: live?.permission))
                    .font(.caption)
            }

            // 模型：按供应商分组（与桌面一致），思考强度单独一个菜单。
            Menu {
                if let models, !models.options.isEmpty {
                    ForEach(providerGroups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.options) { option in
                                Button {
                                    Task { await switchModel(to: option, effort: nil) }
                                } label: {
                                    if option.id == models.current?.id {
                                        Label(option.name, systemImage: "checkmark")
                                    } else {
                                        Text(option.name)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("模型目录未载入")
                }
            } label: {
                Text(modelLabel)
                    .font(.caption)
            }

            Menu {
                if let current = models?.current,
                   let levels = models?.efforts[current.id],
                   !levels.isEmpty {
                    ForEach(levels) { level in
                        Button {
                            Task { await switchModel(to: current, effort: level.id) }
                        } label: {
                            if level.id == models?.currentEffort {
                                Label(level.name, systemImage: "checkmark")
                            } else {
                                Text(level.name)
                            }
                        }
                    }
                } else {
                    Text("该模型没有思考强度选项")
                }
            } label: {
                Text(models?.currentEffort ?? "强度")
                    .font(.caption)
            }

            Spacer(minLength: 0)

            if isBusy {
                Button {
                    Task { await stop() }
                } label: {
                    Image(systemName: "stop.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 6)
    }

    /// 输入框下方一行状态：上下文压力、token、工作区（不显示完整路径，免得被截断）。
    private var statusStrip: some View {
        let live = board.sessions.first { $0.id == summary.id }
        var parts: [String] = []
        if let percent = live?.contextPercent { parts.append("上下文 \(percent)%") }
        if let input = live?.inputTokens, let output = live?.outputTokens {
            parts.append("入 \(input / 1000)k 出 \(output / 1000)k")
        }
        if let workspace = workspaceName(for: live?.cwd) { parts.append(workspace) }
        return Group {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 6)
            }
        }
    }

    private func workspaceName(for cwd: String?) -> String? {
        guard let cwd else { return nil }
        return board.workspaces.first { $0.path == cwd }?.displayTitle
    }

    /// 权限值到中文：主机给的名字是英文，中文更短也更省地方。
    private static let permissionLabels: [String: String] = [
        "read-only": "只读",
        "workspace-write": "工作区可写",
        "danger-full-access": "完全访问",
        "auto": "自动审查",
    ]

    private func permissionName(for value: String?) -> String {
        guard let value else { return "权限" }
        if let known = Self.permissionLabels[value] { return known }
        return permissionOptions.first { $0.value == value }?.name ?? value
    }

    /// 菜单标题：当前模型名（供应商在分组里体现）。
    private var modelLabel: String {
        models?.current?.name ?? "模型"
    }

    /// 按供应商分组，保持目录里的先后顺序。
    private var providerGroups: [(name: String, options: [ModelOption])] {
        guard let models else { return [] }
        var order: [String] = []
        var buckets: [String: [ModelOption]] = [:]
        for option in models.options {
            if buckets[option.providerName] == nil { order.append(option.providerName) }
            buckets[option.providerName, default: []].append(option)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func loadTools() async {
        let harness = Harness(transport: transport)
        if models == nil { models = try? await harness.models(sessionId: summary.id) }
        if permissionOptions.isEmpty {
            permissionOptions = (try? await harness.permissionPresets())?.options ?? []
        }
    }

    private func switchPermission(to preset: String) async {
        do {
            _ = try await Harness(transport: transport).command(sessionId: summary.id, line: "/permission " + preset)
            notice = "权限已切到 " + preset
            await board.load()
        } catch {
            errorText = DshBoard.message(error)
        }
    }

    private func switchModel(to option: ModelOption, effort: String?) async {
        do {
            let harness = Harness(transport: transport)
            try await harness.selectModel(sessionId: summary.id, option: option, reasoningEffort: effort)
            notice = "模型已切到 " + option.name + (effort.map { " · \($0)" } ?? "")
            models = try? await harness.models(sessionId: summary.id)
            await board.load()
        } catch {
            errorText = DshBoard.message(error)
        }
    }

    /// 只在草稿是裸 `/word`（还没打空格）时给候选：打上参数后列表就该让开。
    private var slashFilter: String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = String(draft.dropFirst())
        guard !rest.contains(" ") else { return nil }
        return rest
    }

    private func loadSlash() async {
        guard !slashLoading, slash.isEmpty else { return }
        slashLoading = true
        defer { slashLoading = false }
        let harness = Harness(transport: transport)
        let commands = (try? await harness.commands(sessionId: summary.id)) ?? []
        let skills = (try? await harness.skills(sessionId: summary.id)) ?? []
        slash = commands + skills
    }

    /// 两类候选的发送路径不同：命令交给机器执行，技能只是文本，留在输入框里等参数。
    private func run(_ picked: SlashCommand) async {
        switch picked.kind {
        case .command:
            draft = ""
            do {
                let result = try await Harness(transport: transport).command(sessionId: summary.id, line: "/" + picked.name)
                if let result, !result.isEmpty {
                    notice = result
                } else {
                    notice = "已执行 /" + picked.name
                }
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    notice = nil
                }
                await board.load()
            } catch {
                errorText = DshBoard.message(error)
            }
        case .skill:
            draft = "/" + picked.name + " "
        }
    }

    /// 终止这一轮：机器停下当前 turn，会话还在。
    private func stop() async {
        do {
            try await Harness(transport: transport).cancel(sessionId: summary.id)
            runningNow = false
            await board.load()
        } catch {
            errorText = DshBoard.message(error)
        }
    }

    private var isBusy: Bool { runningNow || board.isRunning(summary.id) }

    private func removeQueued(_ item: QueuedMessage) async {
        do {
            try await Harness(transport: transport).updateQueue(sessionId: summary.id, itemId: item.id, action: .remove)
            await board.load()
        } catch {
            errorText = DshBoard.message(error)
        }
    }

    private func steerQueued(_ item: QueuedMessage) async {
        do {
            try await Harness(transport: transport).updateQueue(sessionId: summary.id, itemId: item.id, action: .steer)
            await board.load()
        } catch {
            errorText = DshBoard.message(error)
        }
    }

    private func saveQueuedEdit(_ item: QueuedMessage, text: String) async {
        do {
            try await Harness(transport: transport).updateQueue(sessionId: summary.id, itemId: item.id, action: .edit(text))
            await board.load()
        } catch {
            errorText = DshBoard.message(error)
        }
    }

    /// 待发送图片的缩略图条。
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let image = UIImage(data: attachment.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 4)
        }
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        defer { pickedItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        let mediaType = type?.preferredMIMEType ?? "image/jpeg"
        let name = "image." + (type?.preferredFilenameExtension ?? "jpg")
        attachments.append(PendingImage(data: data, mediaType: mediaType, name: name))
    }

    /// 从链接里认出本机路径：`file://` 或裸绝对路径。
    private static func localPath(from url: URL) -> String? {
        if url.isFileURL { return url.path }
        if url.scheme == nil, url.absoluteString.hasPrefix("/") { return url.absoluteString }
        return nil
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let requestId = UUID().uuidString
        let images = attachments.map { PromptImage(mediaType: $0.mediaType, base64: $0.base64, name: $0.name) }
        attachments = []
        draft = ""
        let harness = Harness(transport: transport)

        if isBusy {
            // 轮次进行中：按桌面语义排队，先出现在「待发区」，轮次结束后自动发出。
            conversation.showPending(text: text, id: requestId)
            Task {
                do {
                    try await harness.prompt(
                        sessionId: summary.id,
                        requestId: requestId,
                        text: text,
                        images: images,
                        steer: false
                    )
                    await board.load()
                } catch {
                    conversation.dropPending(id: requestId)
                    errorText = DshBoard.message(error)
                }
            }
            return
        }

        runningNow = true
        conversation.showPending(text: text, id: requestId)
        Task {
            do {
                try await harness.prompt(
                    sessionId: summary.id,
                    requestId: requestId,
                    text: text,
                    images: images,
                    steer: false
                )
                await board.load()
            } catch {
                conversation.dropPending(id: requestId)
                errorText = DshBoard.message(error)
            }
        }
    }
}

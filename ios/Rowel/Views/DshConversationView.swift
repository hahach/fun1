import Combine
import DshClientCore
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
    /// 本页唯一的跟随流句柄：换流与停流都经过它（见 `FollowStreamBox`）。
    @State private var followStream = FollowStreamBox()
    /// 跟随流代数：每次 `startFollowing` 自增；旧循环凭它判断自己是否已经过期。
    @State private var followGeneration = 0
    @State private var needsReconnect = false
    @State private var terminal: TerminalSession?
    /// 列表滚动代理：只服务于诊断页点条目时跳到那一行（用户显式指定的一行）。
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showingTrace = false
    @State private var showingText = false
    /// 本页发起的运行状态：发送即真，`turn/end` 即假；桌面侧发起的轮次靠跟随流补。
    @State private var runningNow = false
    /// 退到后台的时刻。回前台时据此判断这一趟离开是否够久、需要重连一次。
    @State private var leftForegroundAt: Date?
    /// 已经展开的过程段。空＝全部折叠；展开状态只活在本页。
    @State private var openGroups: Set<String> = []
    /// 进场取到的那份快照之后又有新内容：退场时要把缓存刷一次（B-138）。
    @State private var snapshotDirty = false
    /// 进场缓存的那一行日志：在 `init` 里备好，`.task` 里报一次。
    /// `init` 会随父视图重算重入，日志写在那里就跟着重入（B-166）。
    @State private var cacheNote: String?
    /// 进页读到的那份位置记录：`.onAppear` 里读，决定这一趟是「落底」还是「回到上次的偏移」。
    @State private var resumePosition: ConversationPosition?
    /// 正在按记录找回偏移：这期间不落底、不跟随。
    @State private var restoringPosition = false
    /// 找回位置的任务：退场与用户接管时取消。
    @State private var positionRestore: Task<Void, Never>?
    /// 这一趟进场已经找过位置：`.task` 随出现重跑，从子页回来不该再把人拽回去。
    @State private var restoreAttempted = false
    /// 活快照到过一次：缓存采纳也会把 `loaded` 置真，首帧日志只认这个标志。
    @State private var sawFirstSnapshot = false
    /// 进场时刻：首帧日志的计时起点。
    @State private var enteredAt: Date?
    /// 上一次「流式合并」日志里的分片数与写回次数：只报增量，累计值不重复刷。
    @State private var streamLoggedFrames = 0
    @State private var streamLoggedFlushes = 0
    /// 草稿的去抖写入任务：每敲一下都写盘没必要。
    @State private var draftSave: Task<Void, Never>?
    /// 跨端草稿同步的执行层。开关关闭时恒为 nil，本页行为与 build 70 完全一致。
    @State private var draftSync: DraftSync?
    /// 冲突提示条要显示的远端快照：非 nil 即显示（此时决策机保证该会话不上行）。
    @State private var draftConflict: DraftSnapshot?
    /// 「已发送」询问条要显示的远端墓碑：非 nil 即显示（另一台已发送、本机还有草稿）。
    @State private var draftConsumed: DraftSnapshot?
    /// 草稿没同步上去（断网、超时、在重试）：输入区上方给一条细提示，别让人以为已经存好了。
    @State private var draftUnsynced = false
    /// 「查看」打开的只读两栏对照。
    @State private var showingDraftDiff = false
    /// 「查看」那一刻抓下的远端全文：冲突解除后 sheet 正在退场，别让它当场变空。
    @State private var draftDiffRemote = ""
    /// 本页已为草稿建过控制器：`.task` 随出现重跑，重复 `enterSession` 会把记账清零。
    @State private var draftEntered = false
    @AppStorage("draft.syncEnabled") private var draftSyncEnabled = true
    /// 输入框的焦点：发送后主动收起键盘，不然正文被键盘压着看不了。
    @FocusState private var composerFocused: Bool
    /// 此刻该冻结的那一段（没有就是 nil）。
    ///
    /// 只存算完的段 id，不存段的帧：段在视口坐标里每帧都在动，把帧数组写进 @State
    /// 等于「滚一下就把整页 body 重算一遍」——行是 VStack 常驻的，展开的大过程块整棵重算
    /// 一遍就是一滑一卡的来源。
    @State private var stickyCandidate: String?
    /// 正在编辑的待发消息。
    @State private var editingQueued: QueuedMessage?
    /// 待发区轮询：inbox 不在事件流里，只随 session/projections 走。
    @State private var projectionsPump: Task<Void, Never>?
    /// 待发送的图片（base64 直接进 prompt，不需要上传）。
    @State private var attachments: [PendingImage] = []
    @State private var pickedItem: PhotosPickerItem?
    /// 从 md 链接点开的文件。
    @State private var previewPath: String?
    /// 滚动容器的像素真源：落底、判离底、翻页补位都问它。
    @State private var scroller: TranscriptScroller
    /// 滑动闸门：手还在滑的时候点到的链接不算数（B-156）。信号来自 scroller。
    @State private var tapGuard: ScrollTapGuard
    /// 正在「先让一拍」的链接点击：再点一次就把旧的作废（B-156）。
    @State private var pendingPreview: Task<Void, Never>?
    /// 吃过一次活快照：进场落底每页只做一次（B-138／B-162）。
    @State private var sawLiveSnapshot = false
    /// 跟随意图：只在手离开、惯性停稳之后按 `scroller.isAtBottom` 回写，长高不改它。
    @State private var follows = true
    /// 等滚动停稳的任务：手指离开后还在惯性滑行时，等它停再回写跟随意图。
    @State private var settleTask: Task<Void, Never>?
    /// 翻页持锁的锚点行：补偿只认这一行在内容坐标里的位移。
    @State private var holdAnchorId: String?
    /// 锚点行在持锁开始那一刻的位置（y0）：只由插入之前的那一次回调确定。
    @State private var holdAnchorY0: CGFloat?
    /// 本次持锁记了几条锚点回调日志（最多 6 条，防刷屏）。
    @State private var anchorCallbackLogs = 0
    /// `/` 之后的候选：技能（文本）与命令（机器执行）两类合在一起。
    @State private var slash: [SlashCommand] = []
    @State private var slashLoading = false
    /// 命令执行后的一行提示：dsh 只回值，界面上原来什么也看不到。
    @State private var notice: String?
    /// 输入框上方那排工具要的数据：模型目录与权限预设。
    @State private var models: ModelCatalog?
    @State private var permissionOptions: [PermissionChoice.Option] = []
    /// 机器的默认权限预设：会话自己的 `permissions` 投影还没到时用它兜底显示（B-150）。
    @State private var accessDefault: PermissionChoice?
    /// 历史图片的缩略图来源。上游的 AttachmentLoader 只在 rowel 自己的 ConversationView
    /// 注入；dsh 路径不注入就永远画占位（B-112）。
    @State private var attachmentLoader: AttachmentLoader
    /// 行表缓存：一页里 `sortedRows` 会被读好几处（body、落底判据、持锁锚点），
    /// 每次全量折叠一遍，展开的大过程块就跟着重算好几遍。
    @State private var rowsCache = RowsCache()
    /// 顶部可见行：可见性回调给的是无序集合，按行表顺序挑出最靠前的那一个存这里。
    /// 用引用盒而不是 `@State` 值：回调在滚动里反复来，写状态等于每来一次就重算整页 body。
    @State private var topVisibleRow = TopVisibleRowBox()
    /// 这一次进场已经落过一次底：同一次进场只认第一次（见 `skipEntryLanding`）。
    @State private var entryLanding = EntryLandingBox()
    /// 键盘此刻是否弹起：只给通知回调写、给同一处读，body 不读。
    @State private var keyboardUp = KeyboardUpBox()
    /// 键盘当前高度：只为日志留一个读数，body 不读。
    @State private var keyboardHeight: CGFloat = 0

    init(transport: DshTransport, summary: SessionSummary, board: DshBoard, parent: SubagentParent? = nil) {
        self.transport = transport
        self.summary = summary
        _board = ObservedObject(wrappedValue: board)
        self.parent = parent
        _attachmentLoader = State(initialValue: AttachmentLoader(harness: Harness(transport: transport), sessionId: summary.id))
        // 滚动容器与滑动闸门同一处建：闸门的信号源就是容器的像素事实。
        let scroller = TranscriptScroller()
        _scroller = State(initialValue: scroller)
        _tapGuard = State(initialValue: ScrollTapGuard(signal: scroller))
        let opening = Conversation(sessionId: summary.id, title: summary.title, cwd: summary.cwd)
        // 先画上一次的快照，网络回来由 follow 的第一帧整体替换（观感上不再等一秒白屏）。
        // 缓存那一路不认忙态：它记的是存盘那一刻的状态，结束它的那条事件不在文件里（B-166）。
        if let cached = SnapshotCache.load(sessionId: summary.id) {
            let busy = opening.adoptCached(snapshot: cached) ? "真" : "假"
            _cacheNote = State(initialValue: "进场采纳缓存 running=\(busy) 条数=\(opening.items.count)")
        }
        _conversation = State(initialValue: opening)
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
                    VStack(alignment: .leading, spacing: Metrics.gap) {
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
                    let rows = sortedRows
                    let lastGroupId: String? = {
                        guard conversation.running, case .process(let group)? = rows.last else { return nil }
                        return group.id
                    }()
                    // 探针只挂一条行：持锁时是锚点行，空闲时是最上面那条条目行。
                    let probeId = holdAnchorId ?? Self.firstItemId(rows)
                    let probeNonce = scroller.holdNonce
                    ForEach(rows) { row in
                        rowBody(row, lastGroupId: lastGroupId)
                            .background(anchorProbe(for: row.id, probeId: probeId, nonce: probeNonce))
                    }
                    // 末尾留一段余量：最后一条消息总能滑到输入区上方，不会被输入框压住（B-154）。
                    Color.clear.frame(height: 28)
                    if conversation.loading {
                        Text("加载中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    }
                    // 行是滚动目标：可见性回调按这一层的行算，进场落点也按行 id 找。
                    .scrollTargetLayout()
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.gap)
                    .coordinateSpace(name: Self.contentSpace)
                    .background(TranscriptScrollProbe(scroller: scroller))
                }
                .coordinateSpace(name: Self.transcriptSpace)
                .scrollDismissesKeyboard(.interactively)
                // 顶部可见行：只由系统报的可见集合算出来，body 不读它（读进 body 就是每帧重算）。
                .onScrollTargetVisibilityChange(idType: String.self, threshold: Self.visibleThreshold) { ids in
                    noteVisibleRows(ids)
                }
                .onPreferenceChange(ProcessFrameKey.self) { frames in
                    // 段的位置每帧都变，但「该冻结哪一段」只在跨段时才变：
                    // 先算再比，值没变就不写状态——滚动期间绝大多数帧到此为止，不重算 body。
                    let next = Self.stickyGroupId(in: frames)
                    if next != stickyCandidate { stickyCandidate = next }
                }
                .onPreferenceChange(HoldAnchorKey.self) { anchor in handleAnchorFrame(anchor) }
                .overlay(alignment: .top) {
                    if let group = stickyGroup {
                        ProcessHeader(group: group, expanded: true, live: group.isRunning) {
                            toggle(group.id)
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 12)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        if !follows {
                            Button {
                                resumeFollow()
                            } label: {
                                Label("回到底部", systemImage: "arrow.down")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Palette.accent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.regularMaterial, in: Capsule())
                                    .overlay(Capsule().stroke(Palette.line, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: follows)
                    .padding(.trailing, Metrics.gutter)
                    .padding(.bottom, 12)
                }
                .modifier(OpensAtEnd(landsAtEnd: !restoresPosition))
                .onAppear {
                    // 进页这一刻读位置记录：视图可能在还没进场时就被建好，读盘只在这里做。
                    resumePosition = ConversationPositionStore.load(sessionId: summary.id, host: positionHost)
                    let recordedOffset = (resumePosition?.offsetY).map { "\(Int($0))" } ?? "无"
                    let recordedRow = resumePosition?.rowId ?? "无"
                    let recordedBottom = resumePosition?.atBottom == true ? "是" : "否"
                    Diagnostics.shared.log(
                        .info, "会话页",
                        "位置记录 偏移=\(recordedOffset) 行=\(recordedRow) 底部=\(recordedBottom)"
                    )
                    attach(proxy)
                    // 内容长高的那一拍问视图要不要落底：策略在 followGrowth 里。
                    scroller.onContentGrowth = { followGrowth() }
                    // 落底到位只记一个事实：进场那一趟只认第一次落底（见 skipEntryLanding）。
                    scroller.onLanded = { _ in
                        entryLanding.done = true
                    }
                    // 进场落在末尾：这一拍内容还没量出，落底排到第一次量出之后。
                    // 要回上次那一行时一律不落底：落点由 `startRestoringPosition` 定。
                    if !restoresPosition { scroller.scrollToBottomSettling("进场") }
                }
                .onChange(of: conversation.loaded) { _, loaded in
                    guard loaded else { return }
                    Diagnostics.shared.log(.info, "会话页", "载入完成 items=\(conversation.items.count) rows=\(sortedRows.count) hasMore=\(conversation.hasMore) 落底=\(follows ? "跟随" : "离底")")
                    prewarmMarkdown()
                    // 要回上次那一行时这一拍不落底、也不把跟随打开：落点由 `startRestoringPosition` 定。
                    guard !restoresPosition, !restoringPosition else { return }
                    // 载入完成就落在末尾：一次按像素落底，内容还没量出时排到量出之后。
                    follows = true
                    landDuringEntry("载入完成")
                }
                .onChange(of: conversation.items.count) { _, _ in
                    ReadState.shared.markRead(summary.id)
                    // 条数变化不落底：过程块（思考、工具卡）每出一张都把视口拽回去，
                    // 折叠块里就表现为逐拍跳动（B-139）。落底由内容长高与轮次结束驱动。
                }
                .onChange(of: isBusy) { _, busy in
                    guard !busy else { return }
                    // 轮次结束：顺手重读一次列表，把 `running` 拉回真值（B-151）。
                    Task { await board.load() }
                    // 落底只在人还跟着的时候做；离底阅读就不打扰。
                    if follows { scroller.scrollToBottom("轮次结束") }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { _ in
                            // 手离开之后才回写跟随意图：拖动途中改 @State 会重算整页 body，
                            // 滚动手势被自己打断，表现为「拉不动」（B-154）。
                            settleFollowsAfterScroll()
                        }
                )
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
                DshQueuedBar(items: conversation.queue, canSteer: conversation.running, isListed: conversation.isListed) { item in
                    editingQueued = item
                } onRemove: { item in
                    Task { await removeQueued(item) }
                } onSteer: { item in
                    Task { await steerQueued(item) }
                }
            }

            VStack(spacing: 0) {
            // 两侧都空就没有可对照的内容：冲突条不占位置（冲突态本身由另一路清）。
            // 优先级：冲突条 > 已发送询问条 > 未同步条——同时出现会把输入区顶得太高，冲突也更要紧。
            if let conflict = draftConflict, !conflict.text.isEmpty || !draft.isEmpty {
                draftConflictBar(conflict)
            } else if draftConsumed != nil {
                draftConsumedBar
            } else if draftUnsynced, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftUnsyncedBar
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
                    .focused($composerFocused)
                    .textFieldStyle(.roundedBorder)
                Button { send() } label: {
                    Text(isBusy ? "排队" : "发送")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(sendTint, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
            }
            .padding(12)

            statusStrip
            }
            .background(Palette.surface)
        }
        .background(Palette.paper)
        // 底部那块空白是容器安全区：让整页铺到屏幕底，装配区自己留 6pt 呼吸。
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(attachmentLoader)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingText = true
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("选择文本")
            }
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
        .toolbarBackground(Palette.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            // 首帧日志的计时起点：`.task` 随视图出现重跑，每次进场重新起算。
            enteredAt = Date()
            if let note = cacheNote { Diagnostics.shared.log(.info, "会话页", note) }
            ReadState.shared.markRead(summary.id)
            // 草稿：换页、回前台、重启都不丢（桌面端的草稿在浏览器里，取不到）。
            enterDraftIfNeeded()
            if terminal == nil { terminal = TerminalSession(transport: transport) }
            conversation.loading = true
            board.startEvents()
            startFollowing()
            startProjectionPolling()
            // 位置：记着行 id 且不在底部就回那一行，其余落底（落底由首帧那一拍做）。
            startRestoringPosition()
            await loadSlash()
            await loadTools()
        }
        .onDisappear {
            stopFollowing()
            stopProjectionPolling()
            pendingPreview?.cancel()
            settleTask?.cancel()
            // 位置先记下来：退场就是离开这一页（换会话也会拆掉本页），下次进场回到这个偏移。
            savePosition()
            stopRestoringPosition()
            scroller.onContentGrowth = nil
            scroller.onLanded = nil
            // 退场前把缓存刷新到最新：不刷的话下次进来先画上一版（B-138）。
            Task { await refreshSnapshotCache() }
        }
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
        .onChange(of: composerFocused) { _, focused in
            guard focused else { return }
            // 键盘顶上来时视口变矮：原来看的是末尾就落回底部，避免中段空一块（B-140）。
            // 离底阅读不在这里动位置：内容按「与输入框的相对距离」重放，见 TranscriptScroller.replayKeyboardOffset。
            Diagnostics.shared.log(.info, "会话页", "键盘 焦点=真 跟随=\(follows ? "是" : "否")")
            if follows { scroller.scrollToBottom("键盘") }
        }
        .onChange(of: draft) { _, text in
            // 先喂决策机（同步、不产生网络），再排本地落盘：控制器在场时由它一并写缓存。
            // 删光按「清空」处理——契约要求立刻写空串，不等 400 ms 去抖（§13.2-8）。
            if text.isEmpty {
                draftSync?.userCleared()
            } else {
                draftSync?.userEdited(text)
            }
            draftSave?.cancel()
            draftSave = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                saveDraft(text)
            }
        }
        .onChange(of: draftSyncEnabled) { _, on in
            if on {
                // 重新打开：按当前输入框接上（旧键的一次性迁移在本页第一次进场时已经做过）。
                draftEntered = false
                draftSync = nil
                enterDraftIfNeeded()
            } else {
                // 关掉即停：撤掉控制器与提示条，此后本页只写本地（与 build 70 同）。
                draftSync?.suspend()
                draftSync = nil
                draftConflict = nil
                draftConsumed = nil
                draftUnsynced = false
                saveDraft(draft)
            }
        }
        .onDisappear {
            draftSave?.cancel()
            // 退场落盘：把输入框的最后一版写进缓存，再停掉同步的去抖计时器（在飞请求照常收尾）。
            saveDraft(draft)
            draftSync?.suspend()
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
        .environment(\.openURL, OpenURLAction { url in
            // 表格单元格这类 SwiftUI 渲染的链接走这里；正文段落的链接走下面那条。
            if let path = Self.localPath(from: url, cwd: summary.cwd) {
                openPreview(path)
                return .handled
            }
            return .systemAction
        })
        // 正文段落由 UITextView 承载，它的链接点击不经过 openURL 环境（B-131）；
        // 同一个判定在这里再挂一次，两条渲染路径进同一个预览。
        .environment(\.dshLinkTap, { url in
            guard let path = Self.localPath(from: url, cwd: summary.cwd) else { return false }
            openPreview(path)
            return true
        })
        // 长按链接的「复制绝对路径」用同一条 cwd 补全相对路径。
        .environment(\.sessionWorkingDirectory, summary.cwd)
        .sheet(isPresented: $showingText) {
            DshCopyTextSheet(pieces: conversation.pieces)
        }
        .sheet(isPresented: $showingTrace) {
            DshTraceView(conversation: conversation) { itemId in
                withTransaction(Transaction(animation: nil)) {
                    scrollProxy?.scrollTo(itemId, anchor: .center)
                }
            }
        }
        .sheet(isPresented: $showingDraftDiff) {
            DraftConflictSheet(
                remote: draftDiffRemote,
                local: draft,
                onLoadRemote: {
                    draftSync?.userAskedRemote()
                    showingDraftDiff = false
                },
                onClose: { showingDraftDiff = false }
            )
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // 只记「真正进后台」的时刻：面容解锁会让 scene 短暂 inactive，
                // 拿 inactive 当起点会把离开时长算成几秒，回前台就不重连了（B-129）。
                if leftForegroundAt == nil { leftForegroundAt = Date() }
                // 挂起前位置也要记：被系统收走时 onDisappear 不一定会跑。
                savePosition()
                // 被系统挂起前也试一次：挂起后这一轮内容就进不了缓存了（B-138）。
                Task { await refreshSnapshotCache() }
            case .active:
                let away = leftForegroundAt.map { Date().timeIntervalSince($0) } ?? 0
                leftForegroundAt = nil
                // 回前台自动重连：后台挂起会掐断 SSH 的长流，而 RPC 可能已经能通——
                // 此时跟随流不出数据也不报错，页面就那么冻着。离开够久就无条件重连一次，
                // 顺带重开跟随流拿新快照。断网期间不启动注定失败的重连（横幅会闪一下），
                // 恢复交给网络监听。
                guard transport.isNetworkSatisfied else { return }
                if needsReconnect || away >= Self.foregroundReconnectAfter {
                    Diagnostics.shared.log(.info, "会话页", "回前台重连：离开 \(Int(away)) 秒、横幅 \(needsReconnect ? "有" : "无")")
                    Task { await reconnect() }
                }
                // 回前台重读一次草稿：离开这段时间里别的设备可能写过（契约 §13.2）。
                draftSync?.refresh()
            default:
                break
            }
        }
        // 键盘布局仍归系统：通知里只记事实并开关「按住」，偏移由 scroller 重放（见 handleKeyboardFrame）。
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            handleKeyboardFrame(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            handleKeyboardHide()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dshTransportRecovered)) { _ in
            // 传输已经修好了：这里只重开流，**不再 refresh**——refresh 会换掉 mux 的物理连接，
            // 又让本页的跟随流失败，反过来再触发一次重连，形成振荡（B-141）。
            // 无条件重开：旧流可能挂在已被换掉的连接上，既不报错也不出数据（B-144）。
            needsReconnect = false
            errorText = nil
            startFollowing()
            startProjectionPolling()
        }
    }

    private func reconnect() async {
        needsReconnect = false
        do {
            try await transport.refresh(trigger: "会话页回前台")
            errorText = nil
            board.startEvents()
            board.restartWorkspaces()
            // 跟随流要重开：重连换掉的是 mux 的物理连接，旧流即使不报错也不会再有数据。
            startFollowing()
            startProjectionPolling()
        } catch {
            errorText = DshBoard.message(error)
            needsReconnect = true
        }
    }

    /// 跟随流：会话开着就一直开。审批不在本视图收，`board` 的 `$events` 统一管，
    /// 这样停在列表页也能看到并作答。
    private func startFollowing() {
        // 本页同一时刻只允许一条跟随流：还有活着的任务说明上一轮没停干净，先记一笔再停旧的。
        if let live = pumping, !live.isCancelled {
            Diagnostics.shared.log(.warn, "会话页", "跟随流重复启动：先停旧的")
        }
        stopFollowing()
        // 代数在创建任务这一拍定下来并传进去：任务体可能晚一拍才开始跑，
        // 那时读到的可能已经是下一次的代数，两条循环会同时以为自己是最新的。
        followGeneration += 1
        let generation = followGeneration
        pumping = Task { await pump(generation: generation) }
    }

    private func stopFollowing() {
        // 先关流再取消任务：取消任务只是让循环不再迭代，dsh 那边那条流还在推（B-164）。
        if followStream.cancelCurrent() {
            Diagnostics.shared.log(.info, "会话页", "跟随流已取消（含 stream.cancel）")
        }
        pumping?.cancel()
        pumping = nil
    }

    /// 跟随流句柄盒：本页同一时刻只有一条活流，换流时旧的那条当场关掉。
    /// 用引用盒装句柄，而不是把 `TunnelStream` 直接放进 `@State`：换流与停流不触发重绘，
    /// 也不把一条网络资源挂进渲染图。只在视图的 MainActor 上下文里用
    /// （`startFollowing`／`stopFollowing`／`pump` 都在这里）。
    private final class FollowStreamBox {
        private var live: TunnelStream?

        /// 换上新流；返回被换下的那条，由调用方 `cancel()`。
        func replace(with next: TunnelStream) -> TunnelStream? {
            let old = live
            live = next
            return old
        }

        /// 取消并摘掉当前流；返回是否真的有一条流在手。
        @discardableResult
        func cancelCurrent() -> Bool {
            guard let stream = live else { return false }
            live = nil
            stream.cancel()
            return true
        }

        /// 只摘掉 sid 对得上的那条：旧循环收尾时不能误伤已经换上来的新流。
        func clear(sid: String) {
            if live?.sid == sid { live = nil }
        }
    }

    /// 待发区不在事件流里，只随 `session/projections` 走：会话开着就轮询，
    /// 桌面侧的插话与被轮次收走的条目才能实时出现/消失（B-117）。
    private func startProjectionPolling() {
        stopProjectionPolling()
        projectionsPump = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, transport.isNetworkSatisfied else { continue }
                if let block = try? await transport.call(
                    "session/projections",
                    .object(["request": .object(["sessionId": .string(summary.id)])])
                ) {
                    conversation.absorbProjections(block)
                }
            }
        }
    }

    private func stopProjectionPolling() {
        projectionsPump?.cancel()
        projectionsPump = nil
    }

    /// 往前翻一页：点下去那一刻就把视口钉住，直到这一页量完才解锁。
    /// 窗口可能在翻页途中被快照替换，那这一页就丢掉。
    private func loadOlder() async {
        guard conversation.hasMore, let before = conversation.oldestSeq, let through = conversation.cursor,
              !conversation.loading else { return }
        let generation = conversation.generation
        // 锚：此刻最上面那条条目行。y0 由 beginHold 逼出来的那一次回调给——
        // 那一拍内容还没插进来，所以拿到的是插入之前的位置。
        holdAnchorId = Self.firstItemId(sortedRows)
        holdAnchorY0 = nil
        anchorCallbackLogs = 0
        // 钉住从点下去那一刻算起：等网络这段时间按钮文案换成「加载中…」，那个高度变化也不许位移。
        scroller.beginHold()
        conversation.loading = true
        defer {
            // 抛错、代数变化、提前返回都要解锁并摘掉探针，否则整页滚不动、探针一直挂着。
            scroller.endHold()
            holdAnchorId = nil
            holdAnchorY0 = nil
            if conversation.generation == generation { conversation.loading = false }
        }
        do {
            let page = try await Harness(transport: transport).page(
                sessionId: summary.id,
                parent: parent,
                throughSeq: through,
                beforeSeq: before,
                maxMessages: 25
            )
            guard conversation.generation == generation else { return }
            // 人往上翻就是在读历史：跟随意图收掉，别让后面的长高把人拽回底部。
            follows = false
            let itemsBefore = conversation.items.count
            conversation.absorb(page: page)
            // 先标记已插入，再看有没有真插进来：空页与失败路径不该触发任何对齐。
            scroller.noteHoldInserted(true)
            if conversation.items.count == itemsBefore {
                // 这一页什么都没插进来：撤回标记，没有要等的内容，直接解锁。
                scroller.noteHoldInserted(false)
                return
            }
            // 文案换回「加载更早的消息」同样是一次高度变化：先换掉，再等这一页稳下来解锁。
            conversation.loading = false
            await scroller.settleHold()
        } catch {
            errorText = DshBoard.message(error)
        }
    }

    /// 一条行：条目直接画，过程段按展开态包一层。
    @ViewBuilder
    private func rowBody(_ row: TranscriptRow, lastGroupId: String?) -> some View {
        switch row {
        case .item(let item, let settled):
            // 条目的输入只有 item 与两个开关，全部参与比较：流式文本变长就不相等，
            // 工具卡状态与轮末时间戳同样在 item 里，闸门吞不掉这些刷新。
            TranscriptItem(item: item, showsSettledAt: settled, showsReasoning: false)
                .equatable()
        case .process(let group):
            // 闸门只在「折叠着、也没在跑」时闭合；展开块与 live 段一律放行（见 ProcessRow）。
            ProcessRow(
                group: group,
                expanded: openGroups.contains(group.id),
                live: group.id == lastGroupId
            ) {
                toggle(group.id)
            }
            .equatable()
        }
    }

    /// 持锁探针：只挂在一条行上，量它在内容坐标里的位置。滚动不改这个坐标，只有上方内容变化才改。
    /// 行在外层 VStack 里，永远在渲染树中——插入把它推下去多少，这里就报多少。
    /// 代数变了就重建探针（`id(nonce)`），位置没变也会有投递：y0 靠这一次投递在插入之前拿到。
    @ViewBuilder
    private func anchorProbe(for id: String, probeId: String?, nonce: Int) -> some View {
        if id == probeId {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: HoldAnchorKey.self,
                    value: HoldAnchorFrame(
                        id: id,
                        minY: geometry.frame(in: .named(Self.contentSpace)).minY,
                        nonce: nonce
                    )
                )
            }
            .id(nonce)
        }
    }

    /// 锚点行在内容坐标里动了：把容器 offset 重设到「点下去那一刻 + 这一行的位移」。
    /// 每次都用固定的 y0 与固定的起点 offset，不累加，所以反复收敛不会越补越多。
    private func handleAnchorFrame(_ anchor: HoldAnchorFrame) {
        guard !anchor.id.isEmpty else { return }
        // 这几条回调足以判死：探针有没有回报、y0 拿到没有、拒绝走的是哪条分支。
        if anchorCallbackLogs < 6 {
            anchorCallbackLogs += 1
            let y0 = holdAnchorY0.map { "\(Int($0))" } ?? "nil"
            Diagnostics.shared.log(
                .info, "会话页",
                "锚点回调 id=\(anchor.id) minY=\(Int(anchor.minY)) 代数=\(anchor.nonce)"
                + " 持锁=\(scroller.isHolding ? "是" : "否") 锚=\(holdAnchorId ?? "nil")"
                + " y0=\(y0) 已插入=\(scroller.holdInserted ? "是" : "否")"
            )
        }
        guard scroller.isHolding, let holdAnchorId, anchor.id == holdAnchorId else { return }
        scroller.noteHoldMeasurement()
        if scroller.holdInserted {
            // 插入之后：这是位移输入。没有 y0 说明这一页没量到，交给 endHold 的兜底。
            guard let y0 = holdAnchorY0 else { return }
            scroller.applyHoldCompensation(y0: y0, y1: anchor.minY)
        } else if holdAnchorY0 == nil {
            // 插入之前的那一拍：定基线，不动位置。
            holdAnchorY0 = anchor.minY
        }
    }

    /// 第一条「正文／用户／提示」行：翻页钉它（段行的身份由段内首条派生，前插后会换主）。
    private static func firstItemId(_ rows: [TranscriptRow]) -> String? {
        rows.first { if case .item = $0 { return true } else { return false } }?.id
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

    /// 把 ScrollViewReader 给的代理留下：诊断页点条目时要用它跳行。
    private func attach(_ proxy: ScrollViewProxy) {
        if scrollProxy == nil { scrollProxy = proxy }
    }

    /// 把缓存刷成本次看到的样子：缓存原来只存「进场那一刻的快照」，这一轮新生成的内容
    /// 永远进不去，下次进来就先画旧的一版、再跳成新的（B-138）。
    ///
    /// 靠再开一条跟随流取它的第一帧，而不是自己拼快照 JSON——拼错格式等于写坏缓存。
    private func refreshSnapshotCache() async {
        guard snapshotDirty else { return }
        let stream = await Harness(transport: transport).follow(sessionId: summary.id, parent: parent, maxMessages: 25)
        defer { stream.cancel() }
        // 服务端不回也不该挂着：3 秒收摊，缓存保持旧样。
        let guardTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            stream.cancel()
        }
        defer { guardTask.cancel() }
        do {
            for try await item in stream.items where item["type"]?.stringValue == "snapshot" {
                // 没写进去就把脏标记留着：下次退场再试，别假装缓存已经是最新的。
                if await noteCacheSave(item) { snapshotDirty = false }
                return
            }
        } catch {
            Diagnostics.shared.log(.warn, "会话页", "缓存刷新失败：\(DshBoard.message(error))")
        }
    }

    /// 进场要不要回上次读的那一行：有记录、不在底部、记到了行 id 与偏移。
    /// 没有行 id 的旧记录一律落底——按偏移硬写在真机上会被丢掉，人反而停在底部。
    private var restoresPosition: Bool {
        guard let resume = resumePosition, !resume.atBottom else { return false }
        guard let rowId = resume.rowId, !rowId.isEmpty else { return false }
        return (resume.offsetY ?? 0) > 1
    }

    /// 位置记忆的键：主机 + 会话，与草稿同一口径。
    private var positionHost: String {
        ConversationPositionStore.hostKey(for: transport.dshSession.endpoint)
    }

    /// 记下此刻的位置：在底部就记底部，停在中间就记视口顶部的偏移。
    private func savePosition() {
        // 恢复途中记的是还没对好的位置：记了反而把上一次的好记录冲掉。
        guard !restoringPosition else { return }
        let y = scroller.offsetY
        // 内容还没量出、或视口贴着顶端：这一拍读到的不是人正在读的位置，
        // 一律按底部记——「偏移=0 底部=否」会让下次进场误判成要回到中间那一屏。
        let measured = scroller.contentHeight > 0 && y >= 1
        let atBottom = measured ? scroller.isAtBottom : true
        // 顶部可见行与偏移一起记：下次进场先按这一行落位，行没了就落底。
        let rowId = measured ? topVisibleRow.id : nil
        ConversationPositionStore.save(
            ConversationPosition(topId: "", rowId: rowId, offsetY: Double(y), atBottom: atBottom, savedAt: Date()),
            sessionId: summary.id,
            host: positionHost
        )
        Diagnostics.shared.log(
            .info, "会话页",
            "位置已记 偏移=\(Int(y)) 行=\(rowId ?? "无") 底部=\(atBottom ? "是" : "否") 判据=\(measured ? "实测" : "内容未量出或贴顶→按底部")"
        )
    }

    /// 进场回到上次读的那一行：行锚命中且落位生效就停在那一行，其余一律落到底部。
    ///
    /// 行锚走 `scrollProxy.scrollTo`（SwiftUI 自己的滚动路径），滚动容器没挂上时它照样能用；
    /// 按记下的偏移硬写 `contentOffset` 则在容器未挂上时被静默丢掉（真机上就是这么停在底部的）。
    /// 补页最多 `positionRestorePages` 页；恢复期间 `follows` 为假，长高不会把人拽走。
    private func startRestoringPosition() {
        stopRestoringPosition()
        guard !restoreAttempted else { return }
        restoreAttempted = true
        guard restoresPosition, let anchorId = resumePosition?.rowId else { return }
        let recorded = CGFloat(resumePosition?.offsetY ?? 0)
        restoringPosition = true
        follows = false
        let startedAt = ProcessInfo.processInfo.systemUptime
        positionRestore = Task { @MainActor in
            defer {
                // 被撤掉的那一条不许把新任务的标志关掉。
                if !Task.isCancelled { restoringPosition = false }
            }
            // 内容还没到（首帧在路上）：行表还是空的，补页与落位都无从谈起。
            while !conversation.loaded {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // 滚动容器可能还没挂上：先等它，最多 500 ms。落位之后要量实到位置，靠的就是它。
            var waitedForContainer = 0
            while !scroller.hasContainer, waitedForContainer < Self.containerWaitSteps {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
                waitedForContainer += 1
            }
            guard scroller.hasContainer else {
                Diagnostics.shared.log(.warn, "会话页", "恢复 等待容器 超时 → 落底")
                landAtBottomAfterRestore("容器未挂上")
                return
            }
            // 先补页直到这一行出现在行表里：行表就是屏幕上自上而下的顺序。
            var pages = 0
            while !rowExists(anchorId) {
                guard !Task.isCancelled else { return }
                // 人自己动了手就不再拽他：位置记忆让位给手的意图。
                if scroller.lastUserScrollAt > startedAt {
                    Diagnostics.shared.log(.info, "会话页", "行锚恢复 行=\(anchorId) 用户已接管")
                    return
                }
                // 首帧还在路上时翻页会直接返回：等它落地，别空转把页数烧光。
                var waited = 0
                while conversation.loading, waited < 150 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    waited += 1
                }
                guard pages < Self.positionRestorePages, conversation.hasMore else { break }
                let before = conversation.items.count
                await loadOlder()
                // 这一页什么都没补进来（代数变化、空页）：再翻也是原地打转。
                if conversation.items.count == before { break }
                pages += 1
            }
            guard !Task.isCancelled else { return }
            guard rowExists(anchorId), placeRowAnchor(anchorId) else {
                Diagnostics.shared.log(
                    .info, "会话页",
                    "行锚恢复未命中 行=\(anchorId) 在表=\(rowExists(anchorId) ? "是" : "否") 补页=\(pages) → 落底"
                )
                landAtBottomAfterRestore("行锚未命中")
                return
            }
            // 落位要等布局落定：过 200 ms 核一次，差得远只记一条，不重试、不硬改偏移。
            let before = scroller.offsetY
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            // 人自己动了手就不再拽他。
            if scroller.isUserScrolling || scroller.lastUserScrollAt > startedAt { return }
            let actual = scroller.offsetY
            // 落位生效没有：视口一动没动、且与记下的偏移差得远，就是这一趟没落上。
            let stuck = abs(actual - before) < 1 && abs(actual - recorded) > 4
            let atTop = actual <= 1 && recorded > 4
            guard !stuck, !atTop else {
                Diagnostics.shared.log(
                    .warn, "会话页",
                    "行锚恢复未落上 行=\(anchorId) 实到=\(Int(actual)) 记录=\(Int(recorded)) 起点=\(Int(before)) → 落底"
                )
                landAtBottomAfterRestore("行锚未落上")
                return
            }
            Diagnostics.shared.log(
                .info, "会话页",
                "行锚恢复 行=\(anchorId) 实到=\(Int(actual)) 记录=\(Int(recorded)) 补页=\(pages)"
            )
            if scroller.isAtBottom { follows = true }
        }
    }

    /// 恢复不成时的唯一出口：落到底部。
    ///
    /// 落底排到内容量出之后再写（`scrollToBottomSettling`），容器晚挂上也能落地；
    /// 按记下的偏移硬写则在容器未挂上时被丢掉，人就停在底部而不是记录的位置。
    private func landAtBottomAfterRestore(_ source: String) {
        follows = true
        scroller.scrollToBottomSettling(source)
    }

    /// 把某一行放到视口顶部：只做布局落位，不写偏移。
    /// - Returns: 滚动代理在不在手；不在手就没法按行落位，调用方落底。
    @discardableResult
    private func placeRowAnchor(_ id: String) -> Bool {
        guard let scrollProxy else { return false }
        withTransaction(Transaction(animation: nil)) {
            scrollProxy.scrollTo(id, anchor: .top)
        }
        return true
    }

    /// 这一行 id 在不在当前行表里：行锚恢复只认表里已有的行。
    private func rowExists(_ id: String) -> Bool {
        sortedRows.contains { $0.id == id }
    }

    /// 可见行集合 → 顶部可见行：官方不保证集合顺序，按当前行表（即屏幕上的先后）取最靠前的一个。
    private func noteVisibleRows(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let visible = Set(ids)
        // 表里一行都没命中（内容刚被整体换掉）：这一拍不写，留着上一条。
        guard let top = sortedRows.first(where: { visible.contains($0.id) })?.id else { return }
        topVisibleRow.id = top
    }

    /// 进场落底的闸门：同一次进场只认第一次落底。
    ///
    /// 进场这一拍内容会被活快照整体换掉，换之前与换之后各落一次，两次之间差的那二十几像素
    /// 就是「先偏下再上跳」。活快照到达即进场结束，此后照常落底。
    /// - Returns: 这一次要不要跳过。
    private func skipEntryLanding(_ source: String) -> Bool {
        // 进场窗口最多 2 秒：活快照一直不来时也不能把跟随一直拦着。
        if let enteredAt, Date().timeIntervalSince(enteredAt) > 2 { return false }
        guard !entryLanding.liveSnapshotSeen, entryLanding.done else { return false }
        Diagnostics.shared.log(.info, "会话页", "落底跳过 来源=\(source)")
        return true
    }

    /// 进场期间的落底：第一次照常落；之后的只排「内容量出之后再落一次」，不先写旧布局的落点。
    private func landDuringEntry(_ reason: String) {
        guard !skipEntryLanding(reason) else {
            scroller.armSettleLanding(reason)
            return
        }
        scroller.scrollToBottomSettling(reason)
    }

    /// 撤掉找回位置的任务：退场、发送、点「回到底部」都要先撤，不然它下一拍还会拽人。
    private func stopRestoringPosition() {
        positionRestore?.cancel()
        positionRestore = nil
        restoringPosition = false
    }

    // MARK: - 键盘

    /// 键盘帧变化：本页只记两件事——弹起/收起这个开关（引用盒，body 不读）与当前高度。
    /// 位置由 `TranscriptScroller` 按「与输入框的相对距离」重放（见 replayKeyboardOffset）。
    ///
    /// 重叠 = 键盘顶到屏幕底之间被盖住的高度，扣掉底部安全区。
    @MainActor
    private func handleKeyboardFrame(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = Self.keyWindow else { return }
        let overlap = max(0, window.bounds.maxY - end.minY - window.safeAreaInsets.bottom)
        // 别处的输入框（设置页、主机编辑页）也发键盘帧：本页视口没变却按自己的状态开始重放，
        // 收起时就把位置写错。收起（重叠=0）一律照旧，保证本页按住的能收尾。
        if overlap > 0, !composerFocused, !keyboardUp.up {
            Diagnostics.shared.log(
                .info, "会话页",
                "键盘 非本页字段，忽略 重叠=\(Int(overlap)) 视口=\(Int(scroller.viewportHeight))"
            )
            return
        }
        if keyboardHeight != overlap { keyboardHeight = overlap }
        if overlap > 0 {
            if !keyboardUp.up {
                keyboardUp.up = true
                // 弹起这一刻定下「内容底到视口底」的距离，此后每一拍按它把偏移写回去。
                scroller.beginKeyboardHold()
            }
        } else if keyboardUp.up {
            keyboardUp.up = false
            scroller.endKeyboardHold()
        }
        logKeyboard(overlap: overlap)
    }

    /// 键盘收起：同样只记事实，并交回 scroller 把内容放回（人已接管滚动就不放）。
    @MainActor
    private func handleKeyboardHide() {
        Diagnostics.shared.log(
            .info, "会话页",
            "键盘收起通知 偏移=\(Int(scroller.offsetY)) 视口=\(Int(scroller.viewportHeight))"
            + " 内容=\(Int(scroller.contentHeight))"
        )
        if keyboardHeight != 0 { keyboardHeight = 0 }
        if keyboardUp.up {
            keyboardUp.up = false
            scroller.endKeyboardHold()
        }
        logKeyboard(overlap: 0)
    }

    /// 键盘那一条事实日志：重叠、视口、偏移、内容四件套，格式固定好对照。
    private func logKeyboard(overlap: CGFloat) {
        Diagnostics.shared.log(
            .info, "会话页",
            "键盘 重叠=\(Int(overlap)) 高度=\(Int(keyboardHeight)) 视口=\(Int(scroller.viewportHeight))"
            + " 偏移=\(Int(scroller.offsetY)) 内容=\(Int(scroller.contentHeight))"
            + " 按住=\(keyboardUp.up ? "是" : "否")"
        )
    }

    /// 当前前台窗口：键盘帧与屏幕底都在它的坐标系里量，不碰已弃用的 `UIScreen.main`。
    @MainActor
    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.keyWindow
    }

    /// 落盘结果如实进日志：超限与失败都不能再报「已刷新」。
    /// - Returns: 真的写进去了没有。
    private func noteCacheSave(_ item: JSONValue) async -> Bool {
        switch await SnapshotCache.save(item, sessionId: summary.id) {
        case .saved(let bytes, let count):
            Diagnostics.shared.log(.info, "会话页", "缓存已保存 字节=\(bytes) 条数=\(count)")
            return true
        case .tooLarge(let bytes):
            Diagnostics.shared.log(.warn, "会话页", "缓存未保存：超过上限 字节=\(bytes)")
            return false
        case .failed(let reason):
            Diagnostics.shared.log(.warn, "会话页", "缓存保存失败：\(reason)")
            return false
        }
    }

    /// 跟随流：开一条、拿快照、一直读下去。**没拿到快照就重开**——mux 刚换过连接时
    /// 这条流可能开在旧连接上：不报错也不出数据，页面就停在"载入中"（B-144）。
    /// 两条流同时 receive 会让流式文本重复（B-164），这里两条防线：换流前先关旧流
    /// （`stream.cancel()` 停掉 dsh 那条流，旧循环下一次迭代就退出），以及每轮循环、每条帧
    /// 之前核对代数（取消失效时旧循环也立刻收手）。`pumping` 只由 `startFollowing` 写。
    private func pump(generation: Int) async {
        let harness = Harness(transport: transport)
        var attempt = 0
        var gotSnapshotEver = false
        while !Task.isCancelled, generation == followGeneration {
            attempt += 1
            Diagnostics.shared.log(.info, "会话页", "跟随流打开（第 \(attempt) 次）代数=\(generation)")
            let stream = await harness.follow(sessionId: summary.id, parent: parent, maxMessages: 25)
            // 开流这一步也要等：等回来时本代可能已经被停掉或换代，这条流绝不能再进句柄盒。
            guard !Task.isCancelled, generation == followGeneration else {
                stream.cancel()
                Diagnostics.shared.log(
                    .info, "会话页",
                    "跟随流关闭 代数=\(generation) 原因=\(Task.isCancelled ? "取消" : "代数变化")"
                )
                return
            }
            // 换流与关旧流绑在一起做：句柄盒里换下来的那条当场取消。
            if let replaced = followStream.replace(with: stream) {
                replaced.cancel()
                Diagnostics.shared.log(.info, "会话页", "跟随流关闭 代数=\(generation) 原因=被替换")
            }
            var gotSnapshot = false
            var closeReason: String?
            do {
                for try await item in stream.items {
                    if Task.isCancelled {
                        closeReason = "取消"
                        break
                    }
                    if generation != followGeneration {
                        closeReason = "代数变化"
                        break
                    }
                    if item["type"]?.stringValue == "snapshot" {
                        gotSnapshot = true
                        gotSnapshotEver = true
                    }
                    receive(item)
                }
                if closeReason == nil {
                    Diagnostics.shared.log(.warn, "会话页", "跟随流结束（第 \(attempt) 次，快照 \(gotSnapshot ? "已到" : "未到")）")
                }
            } catch {
                Diagnostics.shared.log(.warn, "会话页", "跟随流失败（第 \(attempt) 次）：\(DshBoard.message(error))")
            }
            // 迭代退出不等于 dsh 那边的流已经停：收尾一律关流，再摘掉句柄。
            stream.cancel()
            followStream.clear(sid: stream.sid)
            if let closeReason {
                Diagnostics.shared.log(.info, "会话页", "跟随流关闭 代数=\(generation) 原因=\(closeReason)")
                return
            }
            if attempt >= 3 {
                if !gotSnapshotEver {
                    errorText = "跟随流没有响应，点重连"
                    needsReconnect = true
                }
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // 走到这里只可能是被取消、或在这 2 秒退避里代数变了；流在上一轮末尾已经关掉。
        if Task.isCancelled || generation != followGeneration {
            Diagnostics.shared.log(
                .info, "会话页",
                "跟随流关闭 代数=\(generation) 原因=\(Task.isCancelled ? "取消" : "代数变化")"
            )
        }
    }
    private func receive(_ item: JSONValue) {
        switch item["type"]?.stringValue {
        case "snapshot":
            // 进场那一拍显示的是缓存里的旧忙态：活快照到达时两侧对一下，
            // 闪的那一下在日志里就有出处（B-166）。
            let shownBusy = isBusy
            // 缓存采纳也会把 `loaded` 置真：首帧只认这个标志，否则有缓存时这条日志永远不打。
            let firstFrame = !sawFirstSnapshot
            conversation.adopt(snapshot: item)
            if firstFrame {
                sawFirstSnapshot = true
                let ms = enteredAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
                Diagnostics.shared.log(.info, "会话页", "进场首帧 耗时=\(ms)ms 条数=\(conversation.items.count)")
            }
            // 快照是机器此刻的真值：本页发起的那一轮若在这段断线/后台里已经结束，
            // turn/end 没机会到达，乐观标志要跟着收掉（B-161）。真在跑时由
            // conversation.running 兜住，按钮不会误消失。
            if runningNow, !conversation.running {
                Diagnostics.shared.log(.info, "会话页", "快照复位忙态：本页发起的那一轮已结束")
                runningNow = false
            }
            if shownBusy != isBusy {
                Diagnostics.shared.log(
                    .info, "会话页",
                    "忙态更正 \(shownBusy ? "真" : "假")→\(isBusy ? "真" : "假")：活快照到达"
                )
            }
            // 快照就是此刻最新的：先同步清脏（这一拍之后的状态以快照为准），
            // 落盘在后台；写失败再把脏标记放回去，下次退场再试。
            snapshotDirty = false
            Task { if await noteCacheSave(item) == false { snapshotDirty = true } }
            conversation.loading = false
            // 活快照整体换掉内容（缓存那版行数常不一样）：跟随时在这一拍落底，
            // 换完的这份内容量出之后再按像素补一次（B-138／B-162）。
            // 进场那一趟只认第一次落底（见 landDuringEntry）：这一次只排「量出之后再落」，不先写旧布局的落点。
            if !sawLiveSnapshot {
                sawLiveSnapshot = true
                if follows { landDuringEntry("快照") }
                // 活快照到过即进场结束：此后的落底不再拦。
                entryLanding.liveSnapshotSeen = true
            }
        case "event":
            snapshotDirty = true
            if let event = item["event"] {
                switch event["type"]?.stringValue {
                case "turn/start":
                    runningNow = true
                case "turn/end":
                    runningNow = false
                    // 一轮收尾时把流式合并的账报一次：没有新分片就不打。
                    noteStreamMerge()
                    Task { await board.load() }
                default:
                    break
                }
                conversation.apply(event: event)
            }
        case "assistant-stream":
            snapshotDirty = true
            if let frame = item["frame"] { conversation.receiveStream(frame) }
        default:
            break
        }
    }

    /// 报一次流式合并的增量：分片数、真正写回的次数。两者都是累计值，这里只打这一次涨了多少。
    private func noteStreamMerge() {
        let frames = conversation.streamedFrames
        let flushes = conversation.streamedFlushes
        guard frames > streamLoggedFrames else { return }
        Diagnostics.shared.log(
            .info, "会话页",
            "流式合并 帧=\(frames - streamLoggedFrames) 次=\(flushes - streamLoggedFlushes)"
        )
        streamLoggedFrames = frames
        streamLoggedFlushes = flushes
    }

    /// 输入框上方那排：附件（占位）、权限模式、模型，最右是停止。
    private var composerTools: some View {
        let live = board.sessions.first { $0.id == summary.id }
        return HStack(spacing: 14) {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Image(systemName: attachments.isEmpty ? "photo" : "photo.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(attachments.isEmpty ? Color.secondary : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(DshTheme.chip,
                                in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                        .stroke(Palette.line, lineWidth: 0.5))
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
                        if option.value == (live?.permission ?? accessDefault?.current) {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            } label: {
                DshChip(text: permissionName(for: live?.permission))
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
                DshChip(text: modelLabel, tint: .primary)
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
                DshChip(text: models?.currentEffort ?? "强度")
            }

            Spacer(minLength: 0)

            if isBusy {
                Button {
                    Task { await stop() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                        Text("停止").font(.caption)
                    }
                    .foregroundStyle(Palette.bad)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DshTheme.dangerChip, in: Capsule())
                    .overlay(Capsule().stroke(Palette.bad.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 6)
    }

    /// 发送键的填充：有轮次在跑时是「排队」（琥珀），空输入置灰。
    private var sendTint: Color {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        if isBusy { return empty ? Palette.warn.opacity(0.35) : Palette.warn }
        return empty ? Palette.accent.opacity(0.35) : Palette.accent
    }

    /// 输入框下方一行状态：上下文压力、总 token、缓存命中率、工作区（不显示完整路径，免得被截断）。
    private var statusStrip: some View {
        let live = board.sessions.first { $0.id == summary.id } ?? summary
        var parts: [String] = []
        // 百分比读本会话的投影：0.2.2 起列表摘要不再带 contextPressure，列表值只作回退。
        if let fraction = conversation.contextFraction {
            parts.append("上下文 \(Int((fraction * 100).rounded()))%")
        } else if let percent = live.contextPercent {
            parts.append("上下文 \(percent)%")
        }
        if live.totalTokens > 0 {
            parts.append("总 \(Self.tokenText(live.totalTokens))")
            if let rate = live.cacheHitRate { parts.append(String(format: "缓存 %.0f%%", rate * 100)) }
        }
        if let workspace = workspaceName(for: live.cwd) { parts.append(workspace) }
        return Group {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 24)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 12)
            }
        }
    }

    /// token 数按 K/M 进位：三个有效位以内，避免出现「入 8703k」。
    private static func tokenText(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
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
        // 投影还没到时按机器默认显示，别把「权限」两个字摆在那里（B-150）。
        guard let value = value ?? accessDefault?.current else { return "权限" }
        if let known = Self.permissionLabels[value] { return known }
        if let option = permissionOptions.first(where: { $0.value == value }) { return option.name }
        if let option = accessDefault?.options.first(where: { $0.value == value }) { return option.name }
        return value
    }

    /// 菜单标题：当前模型名（供应商在分组里体现）。
    private var modelLabel: String {
        if let name = models?.current?.name { return name }
        if let remembered = ModelMemory.name { return remembered }
        return models == nil ? "模型载入中" : "模型"
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
        if models == nil {
            models = try? await harness.models(sessionId: summary.id)
            if models == nil {
                // 新建会话的 projections 有时还没有答案；等一拍再用机器目录兜底。
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let retried = try? await harness.models(sessionId: summary.id) {
                    models = retried
                } else {
                    models = try? await harness.machineModels()
                }
            }
        }
        if permissionOptions.isEmpty {
            let catalog = try? await harness.permissionPresets()
            permissionOptions = catalog?.options ?? []
            accessDefault = catalog?.defaults
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
        // 主机保存默认是后台异步的；本机先记住，新建会话的标签才不迟钝。
        ModelMemory.remember(option)
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

    /// 忙态两个源：本页发起的轮次、跟随流的 `turn/start..end`（桌面侧发起的轮次只在这里
    /// 出现）。
    ///
    /// 第三个源 `session/list` 的 `running`（`board.isRunning`）已去掉：那是列表某一次载入的
    /// 旧值，进场那一拍正是它最旧的一刻，早已结束的轮次会凭它假忙一下（B-166）。代价是进场后
    /// 到第一份快照到达之间，真在跑的会话显示为不忙——这段时间发出的消息走正文气泡而不是
    /// 待发区，快照到达后由 `conversation.running` 补上「停止」。宁可短暂显示非忙，也不假忙。
    private var isBusy: Bool {
        runningNow || conversation.running
    }

    /// 滚动坐标空间的名字：段在这里量自己的位置，外层据此决定标题何时冻结。
    static let transcriptSpace = "dsh.transcript"
    /// 内容坐标空间的名字：挂在内容容器上，滚动不改变里面的坐标，只有上方内容变化才变。
    static let contentSpace = "dsh.content"

    /// 离开前台超过这么久就重连一次。远大于面容解锁/切控制中心的抖动时长，
    /// 又短于 iOS 掐断空闲连接所需的时间。
    static let foregroundReconnectAfter: TimeInterval = 20

    /// 行锚恢复最多补几页：一页 25 条，补不够就落底。
    private static let positionRestorePages = 10

    /// 恢复前等滚动容器挂上的上限：20 ms 一步、最多 25 步（≈500 ms）。
    /// 弱引用在视图重建时会变 nil，容器没挂上时按偏移写的那一路会被静默丢掉。
    private static let containerWaitSteps = 25

    /// 可见性回调的门槛：0 表示只要露出来就算可见，顶部可见行才落在真正露出的那一行上。
    private static let visibleThreshold: Double = 0.0

    /// 打开会话时的初始落点：交给滚动视图自己的布局锚点，只管进场那一拍。
    /// 尺寸变化不挂锚：往上插页、流式长高、折叠块展开都会改尺寸，钉住末尾会把在上面读旧内容的人拽回末尾。
    /// 要回到上次那一行时 `landsAtEnd` 为假：落点全由 `startRestoringPosition` 决定，系统不先把视口钉到底部。
    private struct OpensAtEnd: ViewModifier {
        let landsAtEnd: Bool

        func body(content: Content) -> some View {
            if landsAtEnd {
                content.defaultScrollAnchor(.bottom, for: .initialOffset)
            } else {
                content
            }
        }
    }

    /// 行表：`conversation.revision` 没变就复用上次折出来的行。
    /// revision 在每一条改 `items`、改 `running` 的路径上都自增，所以这里不会读到过期行。
    private var sortedRows: [TranscriptRow] {
        let revision = conversation.revision
        if rowsCache.revision == revision { return rowsCache.rows }
        let rows = TranscriptLayout.rows(conversation.items, turnEnds: conversation.turnEndIds())
        rowsCache.revision = revision
        rowsCache.rows = rows
        return rows
    }

    /// 需要冻结的段：标题已经滑过顶端、段身还没走完的那一段（取最靠下的一个）。
    ///
    /// 认的是 stickyCandidate 存下的段 id；段的正文仍从当前的行里取，
    /// 所以段在自己生长的这一拍不会画旧内容。
    private var stickyGroup: ProcessGroup? {
        guard let id = stickyCandidate, openGroups.contains(id) else { return nil }
        for row in sortedRows {
            if case .process(let group) = row, group.id == id { return group }
        }
        return nil
    }

    /// 冻结判据：段标题滑过顶端（minY ≤ 8）、段尾还没走完（maxY > 36），取最靠下的一个。
    /// 段的跨度在行里互不重叠，同一时刻至多一段通过，所以「取 minY 最靠下」与判据等价。
    private static func stickyGroupId(in frames: [String: ProcessFrame]) -> String? {
        let inset: CGFloat = 8
        let passed = frames.filter { $0.value.minY <= inset && $0.value.maxY > inset + 28 }
        return passed.max(by: { $0.value.minY < $1.value.minY })?.key
    }

    /// 展开/收起一段。只做高度动画，不加转场；内容从标题下方长出来，上方不位移。
    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if openGroups.contains(id) {
                openGroups.remove(id)
            } else {
                openGroups.insert(id)
            }
        }
    }

    private func removeQueued(_ item: QueuedMessage) async {
        do {
            try await Harness(transport: transport).updateQueue(sessionId: summary.id, itemId: item.id, action: .remove)
            Diagnostics.shared.log(.info, "待发区", "删除完成 item=\(item.id)")
            // 删完立刻反映：本地先移除，再取一次投影对齐（不再等 5 秒轮询，B-142）。
            conversation.dropQueued(id: item.id)
            await refreshProjections()
        } catch {
            Diagnostics.shared.log(.fail, "待发区", "删除失败 item=\(item.id)：\(DshBoard.message(error))")
            if await handleQueueGone(error, item: item) { return }
            errorText = DshBoard.message(error)
        }
    }

    private func steerQueued(_ item: QueuedMessage) async {
        // 先本地置为「已插话」：服务端回包前界面就有反馈，不必等下一拍投影（B-133）。
        conversation.markSteering(id: item.id)
        do {
            try await Harness(transport: transport).updateQueue(sessionId: summary.id, itemId: item.id, action: .steer)
            Diagnostics.shared.log(.info, "待发区", "插话完成 item=\(item.id)")
            await refreshProjections()
        } catch {
            conversation.markQueued(id: item.id)
            Diagnostics.shared.log(.fail, "待发区", "插话失败 item=\(item.id)：\(DshBoard.message(error))")
            if await handleQueueGone(error, item: item) { return }
            // 点下去时这一轮刚好结束（或已进入不再接受插话的阶段）：条目本身没坏，
            // 它会作为下一条消息发出。按服务端的投影重排一次，并说明清楚（B-132）。
            if let rpc = error as? RPCError, case .remote("session/steer-unavailable", _) = rpc {
                notice = "当前轮已不接受插话，这条留在待发区"
                await refreshProjections()
                return
            }
            errorText = DshBoard.message(error)
        }
    }

    /// 内容长高的那一拍：跟着、末尾是正文、手不在滑，就落一次底。
    ///
    /// 过程块（思考、工具卡）长高不落底——那是 B-139 的取舍，所以只在末尾是
    /// 正文气泡时跟随。落底只写一次 `contentOffset`，不排拍子、不猜行高。
    /// 进场那一趟只认第一次落底（见 `skipEntryLanding`），这一拍跳过。
    private func followGrowth() {
        guard follows, endsWithText, !scroller.isUserScrolling else { return }
        guard !skipEntryLanding(TranscriptScroller.growthReason) else { return }
        scroller.scrollToBottom(TranscriptScroller.growthReason)
    }

    /// 载入完成那一拍，把这一页要画的 Markdown 原文交给后台过一遍缓存。
    ///
    /// 行都在常驻的 `VStack` 里，但离屏的文本视图还没建，`MarkdownText` 的解析要到
    /// 滚到那一行才第一次跑。这里提前做掉：低优先级、不 await、不占主线程。
    /// 只在这一拍做一次；翻页补进来的旧内容不重复全量预热。
    private func prewarmMarkdown() {
        var sources: [String] = []
        for item in conversation.items {
            switch item {
            case .assistant(let turn):
                sources.append(turn.text)
            case .tool(let card):
                // 工具卡的正文与输出是纯文本；只有 `ask_user_question` 的计划正文走 Markdown。
                if case .question(let questions, _) = card.presentation {
                    sources.append(contentsOf: questions.compactMap(\.detail))
                }
            case .user, .notice:
                break
            }
        }
        let started = Date()
        Task.detached(priority: .utility) {
            let count = MarkdownWarm.run(sources)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Diagnostics.shared.log(.info, "会话页", "Markdown 预热 条数=\(count) 耗时=\(ms)ms \(MarkdownCache.stats())")
        }
    }

    /// 手离开之后回写跟随意图：只在这一拍与停稳之后各判一次，拖动／滑行途中不动它（B-163）。
    private func settleFollowsAfterScroll() {
        // 手指刚离开这一拍先收一次口：人停在哪儿就按哪儿判，按钮不必等惯性停稳才出现。
        follows = scroller.isAtBottom
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            // 停稳的判据就是这两个标志变假：拖动结束、惯性滑行结束。
            // 上限约两秒：标志万一一直为真，也不能把任务挂死。
            var waited = 0
            while scroller.isUserScrolling, waited < 120 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if Task.isCancelled { return }
                waited += 1
            }
            guard !Task.isCancelled else { return }
            // 惯性滑行会把手离开时的位置带到别处：停稳后（或到上限时）按当时的像素事实再判一次。
            follows = scroller.isAtBottom
            Diagnostics.shared.log(.info, "会话页", "滚动后 Markdown \(MarkdownCache.stats())")
        }
    }

    /// 点「回到底部」：恢复跟随并落在末尾。
    private func resumeFollow() {
        // 人点了「回到底部」就是接管：找回位置的任务到此为止。
        stopRestoringPosition()
        follows = true
        // 可能从很远处跳回来：这一拍行高还没量出，落底之后再按量出的高度补一次。
        scroller.scrollToBottomSettling("回到底部")
    }

    /// 末尾是正文气泡：只有这一种长高才跟着落底。
    private var endsWithText: Bool {
        guard let last = sortedRows.last else { return false }
        if case .item(let item, _) = last, case .assistant = item { return true }
        return false
    }

    /// 重取一次会话投影（待发区、上下文、标题都在里面）：队列操作失败后用它对齐服务端。
    private func refreshProjections() async {
        guard let block = try? await transport.call(
            "session/projections",
            .object(["request": .object(["sessionId": .string(summary.id)])])
        ) else { return }
        conversation.absorbProjections(block)
    }

    private func saveQueuedEdit(_ item: QueuedMessage, text: String) async {
        do {
            try await Harness(transport: transport).updateQueue(sessionId: summary.id, itemId: item.id, action: .edit(text))
            conversation.updateQueuedText(id: item.id, text: text)
            await refreshProjections()
        } catch {
            if await handleQueueGone(error, item: item) { return }
            errorText = DshBoard.message(error)
        }
    }

    /// 待发条目已被运行中的轮次收走（或另一端删掉）：服务端已不认，
    /// 本地清掉并重取投影，而不是挂一条红字让条目钉在界面上（B-117）。
    private func handleQueueGone(_ error: Error, item: QueuedMessage) async -> Bool {
        guard let rpc = error as? RPCError, case .remote("session/queue-item-not-found", _) = rpc else { return false }
        conversation.dropQueued(id: item.id)
        await refreshProjections()
        return true
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

    /// 从链接里认出本机路径：`file://`、裸绝对路径，以及代理常写的、
    /// 相对会话工作目录的相对路径——.md 链接多是相对路径，不补全就点不出
    /// 预览（B-123）。带空格/中文的路径会被百分号编码，先解回来。
    private static func localPath(from url: URL, cwd: String?) -> String? {
        if url.isFileURL { return url.path }
        guard url.scheme == nil, let raw = url.absoluteString.removingPercentEncoding,
              !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return (raw as NSString).standardizingPath }
        if let cwd { return ((cwd as NSString).appendingPathComponent(raw) as NSString).standardizingPath }
        return nil
    }

    /// 点开文件预览。先让一拍再判：手指还按在屏上时分不清「点」与「滑」（B-156）。
    ///
    /// 判定要在让拍之后跑——惯性滑行中伸手按停的那一下，抬起时滚动已经停了，
    /// 只剩时间戳还留着刚才在滑的痕迹。
    private func openPreview(_ path: String) {
        pendingPreview?.cancel()
        pendingPreview = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard tapGuard.allowsTap() else {
                Diagnostics.shared.log(.info, "会话页", "链接点击被滑动闸门拦下 \(path)")
                return
            }
            previewPath = path
        }
    }

    private func send() {
        composerFocused = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // 断网时不发：发出去也只有一种是"挂住"，内容照样丢（B-153）。
        guard transport.isNetworkSatisfied else {
            notice = "网络不可用，这条没发出去"
            return
        }
        let requestId = UUID().uuidString
        let held = attachments
        let images = held.map { PromptImage(mediaType: $0.mediaType, base64: $0.base64, name: $0.name) }
        attachments = []
        draft = ""
        // 发送成功即清：本机缓存立刻删，控制器在场时顺带上行空串（§13.2-8）。
        clearDraftLocal()
        let harness = Harness(transport: transport)

        // 发送总是回到跟随：人发话了就看自己发的话。
        stopRestoringPosition()
        follows = true

        if isBusy {
            // 轮次进行中：按桌面语义只进「待发区」，不占正文气泡——
            // 排队消息在被轮次收走前不会成为真实消息，气泡等不到替换会一直挂着。
            conversation.showQueued(text: text, id: requestId)
            Task {
                do {
                    try await sendPrompt(harness, requestId: requestId, text: text, images: images)
                    draftSync?.sessionBecameNonBlank()
                    // 立刻取一拍投影：机器给这条排队消息分配自己的 id，拿到之前
                    // 它只有本机 requestId，插话/删除都会被回 queue-item-not-found（B-145）。
                    await refreshProjections()
                    await board.load()
                } catch {
                    conversation.dropQueued(id: requestId)
                    restocked(text: text, images: held, error: error)
                }
            }
            return
        }

        runningNow = true
        conversation.showPending(text: text, id: requestId)
        // 刚插进来的气泡这一拍还没量出，落底排到量出之后。
        scroller.scrollToBottomSettling("发送")
        Task {
            do {
                try await sendPrompt(harness, requestId: requestId, text: text, images: images)
                draftSync?.sessionBecameNonBlank()
                await board.load()
                await confirmQueueAfterSend()
            } catch {
                conversation.dropPending(id: requestId)
                runningNow = false
                restocked(text: text, images: held, error: error)
            }
        }
    }

    /// 发出去之后等回执的时限：URLSession 默认要等约 60 秒，挂住太久，人只会以为发丢了。
    private static let sendTimeout: Double = 20

    private struct SendTimedOut: LocalizedError {
        var errorDescription: String? { "发送超时，没收到回执" }
    }

    /// 发一条消息，最多等 `sendTimeout` 秒。超时即取消请求并抛错，交给调用方回填。
    private func sendPrompt(_ harness: Harness, requestId: String, text: String, images: [PromptImage]) async throws {
        let call = Task {
            try await harness.prompt(
                sessionId: summary.id,
                requestId: requestId,
                text: text,
                images: images,
                steer: false
            )
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.sendTimeout * 1_000_000_000))
            call.cancel()
        }
        defer { timer.cancel() }
        do {
            try await call.value
        } catch {
            throw call.isCancelled ? SendTimedOut() : error
        }
    }

    /// 这条没发出去：把文字和图片放回输入框并写回草稿。人后来又打了新内容时以新内容为准，
    /// 只提示不覆盖——丢一整段话比多一条提示难受得多（B-153）。
    private func restocked(text: String, images: [PendingImage], error: Error) {
        errorText = DshBoard.message(error)
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
            if attachments.isEmpty { attachments = images }
            // 回填是用户可见的新内容：同样喂给决策机，别让它以为输入框还是空的。
            draftSync?.userEdited(draft)
            saveDraft(draft)
            notice = "这条没发出去，内容已放回输入框"
        } else {
            notice = "这条没发出去（输入框里已有新内容，未覆盖）"
        }
    }

    // MARK: - 草稿：本地缓存与跨端同步

    /// 草稿缓存的主机键：同一 sessionId 在不同主机上是两份草稿。
    private var draftHost: String { DraftStore.hostKey(for: transport.dshSession.endpoint) }

    /// 进场：开关开着就建控制器（它自己读缓存、先读后写），关着就只读本地缓存。
    /// `.task` 随出现重跑，所以只有第一次进场才 `enterSession`，之后只重读一次。
    private func enterDraftIfNeeded() {
        if draftEntered {
            draftSync?.refresh()
            return
        }
        draftEntered = true
        guard draftSyncEnabled else {
            if draft.isEmpty { draft = DraftStore.text(for: summary.id, host: draftHost) }
            return
        }
        guard draftSync == nil else { return }
        let sync = DraftSync(
            caller: transport,
            sessionId: summary.id,
            isBlank: summary.blank,
            cwd: summary.cwd,
            host: draftHost,
            // 没网就别等请求超时：进会话当场就该显示「草稿未同步」。
            isOnline: { [weak transport] in transport?.isNetworkSatisfied ?? true }
        )
        sync.onBackfill = { text in
            // 两种来路（§13.2-2）：输入框为空时回填远端文本；远端被清空过而本机没有新编辑时回填空串（草稿已被消费）。
            draft = text
            saveDraft(text)
        }
        sync.onSyncState = { on in draftUnsynced = on }
        sync.onConflict = { remote in draftConflict = remote }
        sync.onClearConflict = { draftConflict = nil }
        sync.onConsumed = { remote in draftConsumed = remote }
        sync.onConsumedCleared = { draftConsumed = nil }
        sync.onTooLarge = { _ in
            // 超限不上行、不截断，本地保留（§13.2-10）。
            notice = "草稿过长，暂未同步"
        }
        draftSync = sync
        let local = sync.enter()
        if draft.isEmpty { draft = local }
        // 输入框里的内容优先于缓存：开关刚被打开时，最后一个去抖窗口可能还没落盘。
        if draft != sync.state.localText { sync.userEdited(draft) }
    }

    /// 本地落盘：控制器在场时连记账一起写，关掉同步时只写文本（build 70 的写法）。
    private func saveDraft(_ text: String) {
        if let sync = draftSync {
            sync.persistLocal(text)
        } else {
            DraftStore.saveText(text, for: summary.id, host: draftHost)
        }
    }

    /// 发送成功／删光：本机缓存立刻清掉；控制器在场时顺带上行空串。
    private func clearDraftLocal() {
        if let sync = draftSync {
            sync.userCleared()
        } else {
            DraftStore.remove(for: summary.id, host: draftHost)
        }
    }

    /// 冲突提示条（§13.3）：远端版本时刻 + 前 40 字预览 +「查看」「用本机覆盖」。
    /// 显示期间该会话不上行（决策机保证），这里只把用户的选择交回去。
    private func draftConflictBar(_ remote: DraftSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("远端 · \(Self.draftStamp(remote.updatedAt))")
                    .font(.caption.weight(.medium))
                Text(Self.draftPreview(remote.text))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("查看") {
                draftDiffRemote = remote.text
                showingDraftDiff = true
            }
            .font(.caption)
            Button("用本机覆盖") { draftSync?.userAskedOverwrite() }
                .font(.caption)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 6)
        .background(Palette.line.opacity(0.12))
    }

    /// 「已发送」询问条（§13.2-2）：另一台已发送本会话草稿、本机还有草稿——问「清空」还是「保留」。
    /// 显示期间该会话不上行（决策机保证），这里只把用户的选择交回去；选择当场收起本条。
    private var draftConsumedBar: some View {
        HStack(spacing: 8) {
            Text("这台设备还有草稿，另一台设备已经发送了这条会话的草稿")
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("清空") {
                draftSync?.userChoseClearConsumed()
                draftConsumed = nil
            }
            .font(.caption)
            Button("保留") {
                draftSync?.userChoseKeepConsumed()
                draftConsumed = nil
            }
            .font(.caption)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 6)
        .background(Palette.line.opacity(0.12))
    }

    /// 未同步提示：一行 caption，不抢输入区的地方，也不带按钮——能做的只有等网络。
    private var draftUnsyncedBar: some View {
        Text("草稿未同步，网络恢复后自动补传")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 4)
    }

    /// 远端时刻：`updatedAt` 是服务端毫秒（§11.1），0 表示该键无草稿。
    private static func draftStamp(_ updatedAt: Int) -> String {
        guard updatedAt > 0 else { return "未知时刻" }
        return draftStampFormatter.string(from: Date(timeIntervalSince1970: Double(updatedAt) / 1000))
    }

    private static let draftStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// 前 40 字预览：换行压成空格，免得提示条被撑成两行。
    private static func draftPreview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 40 ? flat : String(flat.prefix(40)) + "…"
    }

    /// 发送刚被接受就取一拍投影：本页把「忙」误判成「不忙」时，消息实际
    /// 进了待发区，乐观气泡在这里立刻转成待发条，而不是闪到下一次五秒
    /// 轮询才被收走（B-117 关闭注记的搭车项；dsh 的 prompt 响应只有
    /// `{accepted:true}`，排队信息只能从投影取）。
    private func confirmQueueAfterSend() async {
        if let block = try? await transport.call(
            "session/projections",
            .object(["request": .object(["sessionId": .string(summary.id)])])
        ) {
            conversation.absorbProjections(block)
        }
    }
}

/// 冲突的只读两栏对照（§13.3）：上＝远端全文、下＝本机当前，底部才是处置入口。
///
/// 只读是刻意的：对照页不做合并，用户看清之后再选「载入远端」或回上一页按「用本机覆盖」。
private struct DraftConflictSheet: View {
    let remote: String
    let local: String
    let onLoadRemote: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pane("远端", remote)
                Divider()
                pane("本机", local)
                Divider()
                HStack(spacing: 12) {
                    Button("关闭", action: onClose)
                        .buttonStyle(.bordered)
                    Button("载入远端", action: onLoadRemote)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
            .navigationTitle("草稿对照")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 两栏各占一半高度，各自滚动：长草稿也不挤成一行。
    private func pane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text.isEmpty ? "（空）" : text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// 行表缓存：(revision, rows)。
///
/// 用引用类型而不是 `@State` 值：`sortedRows` 在 body 里读的时候要顺手写回，
/// 写 `@State` 会被 SwiftUI 判成「更新期间改状态」。revision 变了才算过期。
private final class RowsCache {
    var revision = -1
    var rows: [TranscriptRow] = []
}

/// 顶部可见行的 id：可见性回调在滚动里反复来，写 `@State` 等于每来一次就重算整页 body；
/// 这里只改引用，不触发重绘。
private final class TopVisibleRowBox {
    var id: String?
}

/// 进场落底的两个事实：已经落过一次底、活快照已到（进场结束）。
/// 同上，只给回调写，不进 body。
private final class EntryLandingBox {
    /// 这一次进场已经落过一次底。
    var done = false
    /// 活快照已经到了：进场结束，此后不再拦落底。
    var liveSnapshotSeen = false
}

/// 键盘弹起与否：只给键盘通知写，body 不读。
private final class KeyboardUpBox {
    var up = false
}

/// 持锁锚点行在内容坐标里的位置：滚动不改变它，只有它上方的布局变化才改。
/// `nonce` 是持锁代数：位置没变也要变一次，保证点下去那一拍有投递。
struct HoldAnchorFrame: Equatable {
    var id: String
    var minY: CGFloat
    var nonce: Int
}

struct HoldAnchorKey: PreferenceKey {
    static var defaultValue = HoldAnchorFrame(id: "", minY: 0, nonce: 0)

    static func reduce(value: inout HoldAnchorFrame, nextValue: () -> HoldAnchorFrame) {
        // 同一时刻只有一条行挂探针；没挂探针的行什么都不发，别把已有值冲掉。
        let next = nextValue()
        if !next.id.isEmpty { value = next }
    }
}


import Foundation
import DshClientCore

/// 一条连接上的共享状态：会话全集、工作区、归档集，以及**全局**的待批准与待回答。
///
/// 列表页与每个会话页都读它。之所以放在这里：人常常停在列表上，而 dsh 的 `$events`
/// 一条连接开一份就够——两处各自开流会互相抢答案。
@MainActor
final class DshBoard: ObservableObject {
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var archived: Set<String> = []
    /// 置顶的会话 id，按机器给的顺序（最近置顶在前）。
    @Published private(set) var pinned: [String] = []
    /// 刚由本机新建的空白会话：它们照常显示，否则「新建完什么也没有」。
    @Published private(set) var visibleBlank: Set<String> = []
    @Published private(set) var pending: [ApprovalRequest] = []
    @Published private(set) var questions: [QuestionRequest] = []
    @Published private(set) var errorText: String?
    @Published private(set) var loading = false
    /// 连接状态：列表页据此显示「正在重连／网络不可用」。
    @Published private(set) var link: DshLinkState = .ok
    /// 最近一次列表读完的时刻：下拉刷新有没有生效，看这一行就够。
    @Published private(set) var refreshedAt: Date?

    private let transport: DshTransport
    private var clientId: String?
    private var pump: Task<Void, Never>?
    private var workspacePump: Task<Void, Never>?
    /// 列表载入单飞：连接自愈的回调与用户下拉可能同时触发。
    private var loadTask: Task<Void, Never>?
    private var recoveryObserver: NSObjectProtocol?
    private var networkLostObserver: NSObjectProtocol?
    private var recoveringObserver: NSObjectProtocol?

    init(transport: DshTransport) {
        self.transport = transport
        // 先铺上次的列表与分组：进 App 不再先看到「归档（0）」。
        if let cached = BoardCache.loadSessions() {
            sessions = (cached["items"]?.arrayValue ?? []).compactMap(SessionSummary.init)
        }
        if let cached = BoardCache.loadWorkspaces() {
            applyWorkspaces(cached)
        }
        // 断网提示：恢复后的自愈重拉会把它清掉（B-116）。
        networkLostObserver = NotificationCenter.default.addObserver(
            forName: .dshTransportNetworkLost, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.link = .offline
                self?.errorText = "网络已断开，恢复后将自动重连"
            }
        }
        // 长流静默/断开后的退避重连：RPC 这时往往还能通，只有这条通知能让界面说出真相（B-152）。
        recoveringObserver = NotificationCenter.default.addObserver(
            forName: .dshTransportRecovering, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.link != .offline else { return }
                self.link = .reconnecting
            }
        }
        // 连接自愈（轻量重连或整栈重建）后清掉上一次失败留下的红字并重拉列表（B-114）。
        recoveryObserver = NotificationCenter.default.addObserver(
            forName: .dshTransportRecovered, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.link = .ok
                // $events 泵可能在断链时随流结束而自清，恢复后先补上（幂等）。
                self.startEvents()
                if self.errorText != nil { await self.load() }
            }
        }
    }

    deinit {
        if let recoveryObserver { NotificationCenter.default.removeObserver(recoveryObserver) }
        if let networkLostObserver { NotificationCenter.default.removeObserver(networkLostObserver) }
        if let recoveringObserver { NotificationCenter.default.removeObserver(recoveringObserver) }
    }

    /// 主列表：去掉子代理（它们挂在父会话下）与归档。
    var listSessions: [SessionSummary] {
        sessions.filter { session in
            guard !session.isSubagent, !archived.contains(session.id) else { return false }
            return !session.blank || visibleBlank.contains(session.id)
        }
    }

    var archivedSessions: [SessionSummary] {
        sessions.filter { archived.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 工作区分组、待批准上浮，都交给上游的纯逻辑（`SessionBoard`）。
    var board: SessionBoard {
        SessionBoard(
            sessions: listSessions.filter { !pinned.contains($0.id) },
            workspaces: workspaces,
            waitingOn: Set(pending.map(\.sessionId)).union(questions.map(\.sessionId))
        )
    }

    /// 置顶区：机器给的顺序，去掉已归档的。
    var pinnedSessions: [SessionSummary] {
        pinned.compactMap { id in listSessions.first { $0.id == id } }
    }

    func pin(_ sessionId: String) async {
        do {
            try await Harness(transport: transport).pin(sessionId: sessionId)
            pinned.removeAll { $0 == sessionId }
            pinned.insert(sessionId, at: 0)
        } catch {
            report(error)
        }
    }

    func unpin(_ sessionId: String) async {
        do {
            try await Harness(transport: transport).unpin(sessionId: sessionId)
            pinned.removeAll { $0 == sessionId }
        } catch {
            report(error)
        }
    }

    /// 分组：两级都沿用桌面侧的手工顺序。
    ///
    /// dsh 给工作区与「工作区里的会话」都维护手工顺序（`sessionIds` 就是那个顺序，
    /// 拖动时机器再推 `order` 增量），所以这里不按活动时间重排；只有不在任何工作区
    /// ledger 里、靠 cwd 归过来的会话，才按最近活动排在组尾。
    var groups: [DshGroup] {
        var remaining = listSessions.filter { !pinned.contains($0.id) }
        var made: [DshGroup] = []

        for workspace in workspaces {
            var members: [SessionSummary] = []
            var claimed: Set<String> = []
            for id in workspace.sessionIds {
                guard let match = remaining.first(where: { $0.id == id }) else { continue }
                claimed.insert(id)
                members.append(match)
            }
            if let path = workspace.path, !path.isEmpty {
                let wanted = WorkspacePlacement.canonical(path)
                var loose: [SessionSummary] = []
                for session in remaining where !claimed.contains(session.id) {
                    guard let cwd = session.cwd, WorkspacePlacement.canonical(cwd) == wanted else { continue }
                    claimed.insert(session.id)
                    loose.append(session)
                }
                members.append(contentsOf: loose.sorted { $0.updatedAt > $1.updatedAt })
            }
            remaining.removeAll { claimed.contains($0.id) }
            guard !members.isEmpty else { continue }
            made.append(DshGroup(id: workspace.id, title: workspace.displayTitle, sessions: members))
        }

        let loose = remaining.sorted { $0.updatedAt > $1.updatedAt }
        if !loose.isEmpty {
            made.append(DshGroup(id: "rowel.ungrouped", title: "未分组", sessions: loose))
        }
        return made
    }

    /// 某个会话的直接子代理会话，按最近活动排。
    func children(of parentId: String) -> [SessionSummary] {
        sessions.filter { $0.parentSessionId == parentId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func approvals(for sessionId: String) -> [ApprovalRequest] {
        pending.filter { $0.sessionId == sessionId }
    }

    func questions(for sessionId: String) -> [QuestionRequest] {
        questions.filter { $0.sessionId == sessionId }
    }

    /// 该工作区里现成可复用的空白会话：dsh 只在客户端显式给 `sessionId` 时复用，
    /// 不给就每点新建一条（B-106 的成因）。
    func blankSession(inWorkspacePath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return sessions.first { $0.blank && !archived.contains($0.id) && $0.cwd == path }?.id
    }

    /// 重开 `workspace/follow`：桌面侧改了顺序/归档时，手动刷新与回前台都要拿一份新 baseline。
    func restartWorkspaces() {
        workspacePump?.cancel()
        workspacePump = nil
        startWorkspaces()
    }

    /// 改名先落到本地：`session/list` 的 projection 有一拍延迟，界面不该等它。
    /// 新建后先让它可见：`blank` 会话本来被滤掉，刚建完就消失会像失败。
    func markVisibleBlank(_ sessionId: String) {
        visibleBlank.insert(sessionId)
    }

    /// 新建会话的本地摘要：只给导航用，不插进列表。
    ///
    /// 插进 sessions 会留下一条刷新也删不掉的行（它躲过 blank 过滤，直到重连清空 visibleBlank）——
    /// 所以列表始终以 session/list 为准，这里只按同一形状造一份给 destination 用。
    func blankSummary(_ sessionId: String, cwd: String?) -> SessionSummary? {
        var fields: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "blank": .bool(true),
            "running": .bool(false),
            "updatedAt": .number(Date().timeIntervalSince1970 * 1000),
        ]
        if let cwd { fields["cwd"] = .string(cwd) }
        return SessionSummary(.object(fields))
    }
    func applyTitle(_ title: String, to sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].title = title
    }

    func isRunning(_ sessionId: String) -> Bool {
        sessions.first { $0.id == sessionId }?.running ?? false
    }

    /// 清掉上一次失败留下的红字（下拉刷新成功、连接自愈后都走它）。
    func clearError() { errorText = nil }

    func report(_ error: Error) {
        errorText = DshBoard.message(error)
        Diagnostics.shared.log(.fail, "界面", errorText ?? "")
    }

    /// 一行能读的错误：`NSError` 的 `debugDescription` 是一长串，界面上放不下。
    nonisolated static func message(_ error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty { return described }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)：\(ns.localizedDescription)"
    }

    // MARK: - 载入

    func load() async {
        if let inFlight = loadTask {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in await self.performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        loading = true
        defer { loading = false }

        // 先自己重试两拍：dsh 偶尔回一个非 JSON 的响应（网关错误页），
        // 立刻整栈重连会把一次抖动放大成一次重建。
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let raw = try await transport.call("session/list", .object(["_request": .emptyObject]))
                sessions = (raw["items"]?.arrayValue ?? []).compactMap(SessionSummary.init)
                BoardCache.saveSessions(raw)
                errorText = nil
                refreshedAt = Date()
                return
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
        }

        // 三次都不行才认为连接已死：重建一次再试。
        do {
            try await transport.refresh(trigger: "列表载入失败")
            let raw = try await transport.call("session/list", .object(["_request": .emptyObject]))
            sessions = (raw["items"]?.arrayValue ?? []).compactMap(SessionSummary.init)
            BoardCache.saveSessions(raw)
            errorText = nil
            startEvents()
        } catch {
            report(error)
            if let lastError, DshBoard.message(lastError) != DshBoard.message(error) {
                Diagnostics.shared.log(.warn, "界面", "首次失败：\(DshBoard.message(lastError))")
            }
        }
    }
    /// 常驻 `workspace/follow`：baseline 定分组与归档/置顶集，后续变更就重读一次 baseline。
    func startWorkspaces() {
        guard workspacePump == nil else { return }
        workspacePump = Task { [weak self] in
            guard let self else { return }
            let stream = await Harness(transport: self.transport).followWorkspaces()
            do {
                for try await item in stream.items {
                    self.consumeWorkspace(item)
                }
            } catch {
                // 老版本 dsh 没有这个流：列表退回不分组，不算错误。
            }
            self.workspacePump = nil
        }
    }

    private func applyWorkspaces(_ value: JSONValue) {
        BoardCache.saveWorkspaces(value)
        workspaces = (value["items"]?.arrayValue ?? []).compactMap(Workspace.init)
        archived = Set((value["archivedSessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue })
        pinned = (value["pinnedSessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
    }

    /// 增量：baseline 与 replace 带全集，其余按 type 分别应用。
    private func consumeWorkspace(_ item: JSONValue) {
        switch item["type"]?.stringValue {
        case "baseline", "replace":
            applyWorkspaces(item["value"] ?? .emptyObject)
        case "upsert":
            guard let view = item["workspace"].flatMap(Workspace.init) else { return }
            if let index = workspaces.firstIndex(where: { $0.id == view.id }) {
                workspaces[index] = view
            } else {
                workspaces.append(view)
            }
        case "remove":
            guard let id = item["workspaceId"]?.stringValue else { return }
            workspaces.removeAll { $0.id == id }
        case "order":
            // 桌面侧拖过的顺序：按 ids 重排，没提到的追加在后面。
            let ids = (item["workspaceIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
            guard !ids.isEmpty else { return }
            let byId = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            workspaces = ids.compactMap { byId[$0] } + workspaces.filter { !ids.contains($0.id) }
        case "archived":
            archived = Set((item["archivedSessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue })
        case "pinned":
            pinned = (item["pinnedSessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
        default:
            break
        }
    }

    // MARK: - 审批与提问

    /// 消费 `$events`：`ready` 记下 clientId，`waterfall` 收集待回答，`cancel` 撤下。
    func startEvents() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            let harness = Harness(transport: self.transport)
            let stream = await harness.events()
            do {
                for try await item in stream.items {
                    self.consume(item)
                }
            } catch {
                // 流断了：待回答随连接失效，重连后由 Host 重新推送。
            }
            self.pending = []
            self.questions = []
            self.pump = nil
        }
    }

    private func consume(_ item: JSONValue) {
        switch item["type"]?.stringValue {
        case "ready":
            clientId = item["clientId"]?.stringValue
            pending = []
            questions = []
        case "cancel":
            guard let id = item["eventId"]?.stringValue else { return }
            pending.removeAll { $0.id == id }
            questions.removeAll { $0.id == id }
        case "waterfall":
            guard let eventId = item["eventId"]?.stringValue,
                  let clientId,
                  let agentId = item["agentId"]?.stringValue else { return }
            // 子代理以自己的名义提问；卡片放到长父会话里，因为人正看着那里。
            // 作答指名的仍是请求号，故照样能送达子代理。
            let sessionId = owner(of: agentId)
            let request = item["request"] ?? .emptyObject
            switch item["event"]?.stringValue {
            case "approval/request":
                let approval = ApprovalRequest(
                    id: eventId,
                    clientId: clientId,
                    sessionId: sessionId,
                    approvalId: request["callId"]?.stringValue ?? "",
                    toolName: request["toolName"]?.stringValue ?? "工具调用",
                    reason: request.path("displayReason", "en")?.stringValue ?? request["reason"]?.stringValue,
                    at: Date()
                )
                pending.removeAll { $0.id == eventId }
                pending.append(approval)
            case "user-questions/request":
                let items = (request["questions"]?.arrayValue ?? []).compactMap(QuestionItem.init(json:))
                guard !items.isEmpty else { return }
                questions.removeAll { $0.id == eventId }
                questions.append(QuestionRequest(id: eventId, clientId: clientId, sessionId: sessionId, items: items, at: Date()))
            default:
                break
            }
        default:
            break
        }
    }

    /// 子代理的请求记到它所在的主会话上：按 `parentSessionId` 一路走到顶。
    private func owner(of sessionId: String) -> String {
        var current = sessionId
        var guardCount = 0
        while let row = sessions.first(where: { $0.id == current }),
              let parent = row.parentSessionId,
              guardCount < 8 {
            current = parent
            guardCount += 1
        }
        return current
    }

    func stopEvents() {
        pump?.cancel()
        pump = nil
        pending = []
        questions = []
    }

    /// 把一条会话归档：机器只把它从分组面藏起来，日志还在。
    func archive(_ sessionId: String) async {
        do {
            try await Harness(transport: transport).archive(sessionId: sessionId)
            archived.insert(sessionId)
            pinned.removeAll { $0 == sessionId }
        } catch {
            report(error)
        }
    }

    /// 把一条归档会话放回列表。
    func unarchive(_ sessionId: String) async {
        do {
            try await Harness(transport: transport).unarchive(sessionId: sessionId)
            archived.remove(sessionId)
            await load()
        } catch {
            report(error)
        }
    }

    func answer(_ request: ApprovalRequest, allow: Bool) async {
        do {
            try await Harness(transport: transport).answerApproval(request, allow: allow)
            pending.removeAll { $0.id == request.id }
        } catch {
            report(error)
        }
    }

    func answer(_ request: QuestionRequest, answers: [String: QuestionAnswer]) async {
        do {
            try await Harness(transport: transport).answerQuestion(request, answers: answers)
            questions.removeAll { $0.id == request.id }
        } catch {
            report(error)
        }
    }
}

/// 列表里的一节：一个工作区，或落单的会话。
struct DshGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var sessions: [SessionSummary]
}
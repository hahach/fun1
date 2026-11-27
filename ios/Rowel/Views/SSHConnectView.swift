import SwiftUI
import DshClientCore

/// T2 的入口：已保存的主机列表 + 状态块（状态文案与「重新连接」／「进入会话」两个按钮）。
///
/// 多主机：档案按 `user@host:port` 去重存在 `profiles.json`，旧的单档案 `profile.json`
/// 照样读得到（首次升级不会丢连接）。密钥明文存盘，界面只显示指纹；改密钥、清除密钥或删除主机需认证。
///
/// 当前主机的地址与私钥都不单独成段：列表里的 ✓ 就是当前主机；`+`（新增）与
/// 行内左滑「编辑」推进同一个编辑页（地址 + 私钥两栏，两个都填才可提交），
/// 编辑就是把这一台替换掉。
struct SSHConnectView: View {
    @Environment(\.dismiss) private var dismiss
    /// 本地通知：只在连接真正就绪那一拍问一次权限（见 installTransport）。
    @Environment(\.notifier) private var notifier: Notifier?

    @State private var address = ""
    @State private var keyText = ""
    @State private var status = "未连接"
    @State private var errorText: String?
    @State private var busy = false
    @State private var summary: String?
    @State private var transport: DshTransport?
    /// 降级会话：SSH 已连、dsh 未就绪（`openDegrading` 交回来的那条连接）。
    /// 非 nil 时**不建** `DshTransport`——降级会话的 `localPort` 是 0 或旧值、凭据为空，
    /// 建出来也连不上；界面只留「打开 SSH 终端」「重试 dsh」两个自救动作。
    /// 它与 `transport` 互斥：同一时刻只有一条命，要么 dsh 就绪、要么停在降级态。
    @State private var degradedSession: DshSession?
    /// 降级原因的界面副本（`degradedSession.degraded`），显示的就是它的 `message`。
    @State private var degraded: Degraded?
    /// 降级态的自救终端。收起 sheet 不关 shell，再点「打开 SSH 终端」回到同一个会话。
    @State private var shellSession: TerminalSession?
    @State private var showShell = false
    /// 正在「重试 dsh」：挡住连点，也挡住同时去开 shell。
    @State private var retrying = false
    /// 正在「打开 SSH 终端」：探活那一下。
    @State private var openingShell = false
    @State private var profiles: [Profile] = []
    @State private var savedProfile: Profile?
    @State private var showSessions = false
    /// 当前推进导航栈的主机编辑页（新增／编辑）；`nil` 表示停在列表页。
    @State private var hostEditor: HostEditor?

    /// 导航目的地身份。`.navigationDestination(item:)` 要的是 `Hashable`；`Profile` 本身
    /// 不 Hashable，这里按 `address` 定义相等与哈希（地址在列表里本来就是唯一的键）。
    private enum HostEditor: Hashable {
        case add
        case edit(Profile)

        static func == (lhs: HostEditor, rhs: HostEditor) -> Bool {
            switch (lhs, rhs) {
            case (.add, .add): return true
            case (.edit(let one), .edit(let other)): return one.address == other.address
            default: return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .add: hasher.combine("add")
            case .edit(let profile): hasher.combine(profile.address)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !profiles.isEmpty {
                    Section("已保存的主机") {
                        ForEach(profiles, id: \.address) { profile in
                            Button {
                                select(profile)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.host)
                                            .font(.body)
                                        Text(profile.address)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if savedProfile?.address == profile.address {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .disabled(busy)
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) {
                                    guard !busy else { return }
                                    Task {
                                        guard await SensitiveGate.shared.authenticate(reason: "删除已保存的主机") else { return }
                                        remove(profile)
                                    }
                                }
                                // 编辑与工具栏 `+` 是同一个表单，编辑的就是这一行代表的这一台。
                                Button("编辑") {
                                    guard !busy else { return }
                                    hostEditor = .edit(profile)
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }

                Section("状态") {
                    Text(status)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    if let summary {
                        Text(summary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let transport {
                        Text("已连到 \(transport.dshSession.endpoint.user)@\(transport.dshSession.endpoint.host)，可以直接进入会话。")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("连接中断、换了密钥或想换一台主机时，点「重新连接」。")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    // 降级块：SSH 已连、dsh 未就绪。上屏文案就是 Core 给的 `message`，
                    // 两个动作：开 SSH 终端上去把 dsh 拉起来，或直接复用同一条 SSH 重试。
                    if let degraded {
                        Text(degraded.message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        Text("SSH 已连上：可以打开 SSH 终端把 dsh 拉起来，或直接重试 dsh。")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                Task { await openShell() }
                            } label: {
                                Text(openingShell ? "打开中…" : "打开 SSH 终端")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(retrying || openingShell)

                            Button {
                                Task { await retryDsh() }
                            } label: {
                                Text(retrying ? "重试中…" : "重试 dsh")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(retrying || openingShell)
                        }
                    }
                    // 两个入口并排：左「重新连接」（未连接且没有降级会话时不可点）、
                    // 右「进入会话」（降级态下没有可进的会话，按钮置灰、标签换成「dsh 未就绪」）。
                    HStack(spacing: 12) {
                        Button {
                            Task { await connect() }
                        } label: {
                            Text("重新连接")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy || retrying || (transport == nil && degradedSession == nil) || address.isEmpty || keyText.isEmpty)

                        Button {
                            Task {
                                if transport == nil {
                                    // connect() 成功后自己置 showSessions。
                                    await connect()
                                } else {
                                    showSessions = true
                                }
                            }
                        } label: {
                            Text(enterLabel)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || retrying || degradedSession != nil || (transport == nil && (address.isEmpty || keyText.isEmpty)))
                    }
                    // 降级态下没有 transport，但有一条活的 SSH：「断开连接」必须照样可点，
                    // 而且真的把那条连接关掉（见 disconnect()）。
                    if transport != nil || degradedSession != nil {
                        Button("断开连接", role: .destructive) {
                            Task { await disconnect() }
                        }
                        .disabled(retrying)
                    }
                }
            }
            .navigationDestination(isPresented: $showSessions) {
                if let transport {
                    DshSessionListView(transport: transport)
                }
            }
            // 降级态的自救终端：全屏 sheet。收起 sheet 不关 shell（`TerminalSession` 的语义），
            // 关掉的只是「看得见」这一层；要断连接请走「断开连接」。
            .sheet(isPresented: $showShell) {
                NavigationStack {
                    if let shellSession {
                        DshTerminalScreen(session: shellSession)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("关闭") { showShell = false }
                                }
                            }
                    }
                }
            }
            .task { loadProfiles() }
            .navigationTitle("连接 dsh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    // 设置页在没有连接时也进得去：齿轮只带开关项，不带连接。
                    NavigationLink {
                        DshSettingsView(transport: transport)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    NavigationLink {
                        DshDiagnosticsView()
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        hostEditor = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(busy)
                    Button("关闭") { dismiss() }
                }
            }
            // 新增与编辑都推入导航栈里的一页（不是弹窗）：填一屏内容不怕手滑收起。
            .navigationDestination(item: $hostEditor) { destination in
                switch destination {
                case .add:
                    HostEditorPage(mode: .add, onSubmit: add)
                case .edit(let profile):
                    // 改的是点开左滑的那一台；落盘语义全在 edit(original:address:key:)，
                    // 「清除密钥」落在 clearStoredKey(_:)。
                    HostEditorPage(
                        mode: .edit(profile),
                        onSubmit: { newAddress, newKey in
                            await edit(original: profile, address: newAddress, key: newKey)
                        },
                        onClearKey: { clearStoredKey(profile) }
                    )
                }
            }
        }
    }

    private var enterLabel: String {
        if transport != nil { return "进入会话" }
        // 降级态没有可进的会话（`DshTransport` 根本没建），按钮已置灰，标签说明原因。
        if degradedSession != nil { return "dsh 未就绪" }
        return busy ? "连接中…" : "连接并进入"
    }

    private func setStatus(_ value: String) {
        Task { @MainActor in status = value }
    }

    private var store: ProfileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return ProfileStore(directory: base.appendingPathComponent("dafeiyu-dsh-client", isDirectory: true))
    }

    /// 载入全部档案；没有选中过就默认用第一条（通常就是上次连过的那台）。
    private func loadProfiles() {
        guard address.isEmpty, keyText.isEmpty else { return }
        profiles = (try? store.loadAll()) ?? []
        guard let first = profiles.first else { return }
        select(first)
        setStatus("已载入 \(profiles.count) 条主机档案")
    }

    private func select(_ profile: Profile) {
        // 连接进行中不允许换选中项：换台会改掉 address/keyText，正在跑的那次连接就串了密钥。
        // 重试 dsh 期间同理：换台会把正在重试的那条降级会话放掉。
        guard !busy, !retrying else { return }
        // 换到别的主机就把旧连接放掉，免得「进入会话」进的是上一台。
        if let live = transport, live.dshSession.endpoint != profile.endpoint {
            SensitiveGate.shared.sessionEnded()
            transport = nil
            Task { await live.close() }
        }
        // 降级会话同理：它挂在上一台的 SSH 上，换了主机就不能再拿它「重试 dsh」或开 shell。
        if let stale = degradedSession, stale.endpoint != profile.endpoint {
            dropDegradedSession()
        }
        address = profile.address
        savedProfile = profile
        keyText = profile.privateKeyPEM
    }

    /// 工具栏 `+` 的落点：解析地址、写私钥、落盘、选中它，并立刻进列表。
    ///
    /// 地址输入框已经撤掉，新增主机就这一条入口，所以档案当场落盘——否则关掉这个
    /// 视图再进来就找不回刚敲的地址。
    ///
    /// **同一个 endpoint 已在列表里且密钥不同时，用这次输入的密钥覆盖档案里那把**，
    /// 并且和 `edit(original:address:key:)` 的替换密钥走同一道 `SensitiveGate`：
    /// 改已存主机的密钥只有一条标准，认证不过就整条不落盘。覆盖范围仅限这一条 endpoint：
    /// `profile` 是旧档案的值拷贝，改的只是 `privateKeyPEM`，`knownHosts`
    /// （已信任的主机指纹）原样带过；其它档案不受影响，写盘由 `upsert` 按 endpoint
    /// 整条替换。密钥格式不对在这里就挡下，不落盘。
    private func add(address raw: String, key: String) async -> String? {
        guard !busy else { return "连接进行中，请稍后再试" }
        let endpoint: Endpoint
        do {
            endpoint = try Endpoint.parse(raw, defaultUser: "root")
        } catch {
            return parseMessage(error)
        }
        // 粘贴常带首尾换行：校验、落盘、以及之后连接读到的，都是这份去空白后的文本。
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.hasPrefix("-----BEGIN") else {
            return "私钥需以 -----BEGIN 开头，整份粘贴 OpenSSH 私钥"
        }

        let existing = profiles.first { $0.endpoint == endpoint }
        if let existing, existing.privateKeyPEM != trimmedKey {
            // 与 edit(original:address:key:) 的替换密钥同一道门：改已存主机的密钥只有一条标准。
            guard await SensitiveGate.shared.authenticate(reason: "替换 SSH 密钥") else {
                return "已取消替换"
            }
        }

        var profile = existing ?? Profile(
            user: endpoint.user,
            host: endpoint.host,
            port: endpoint.port,
            privateKeyPEM: ""
        )
        profile.privateKeyPEM = trimmedKey
        // 落盘失败就整条不生效：不选中、不报成功文案，错误回到表单上。
        do {
            profiles = try store.upsert(profile)
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
        // select 会把 keyText 置成刚存下的这份，「进入会话」用的就是它。
        select(profile)
        setStatus(existing == nil ? "已添加 \(profile.address)" : "已更新 \(profile.address) 的密钥")
        return nil
    }

    /// 左滑「编辑」的落点：把这一台替换成表单里的地址与密钥（地址与密钥都可改）。
    ///
    /// 落盘只有一条路：先在内存里算出目标列表（旧的那条一律摘掉），再一次 `saveAll`。
    /// 地址没变就是原地更新，地址变了也不会留下旧的一条。新地址撞上**另一台**已存
    /// 主机时就地拒绝，不落盘；改密钥与 `add` 走同一道 `SensitiveGate`，认证取消
    /// 则整条不落盘（表单里的错误条会留着，弹窗不关）。
    ///
    /// 什么都没改（地址解析成同一个 endpoint、密钥去空白后与档案里那份一致）时直接
    /// 返回 `nil` 关掉弹窗：不落盘、不断开、不改状态文案。
    ///
    /// 编辑的是当前这台时直接断开：地址变了要重连，密钥换了也是，不做「只改密钥就
    /// 不断开」的特例；关会话的写法照 `select(_:)`。编辑别的台只动档案，连接与
    /// 选中项都不碰。`knownHosts`（已信任的主机指纹）随档案带走——它按 `host:port`
    /// 存键，地址变了那条自然不再命中，改回原地址时还能复用。
    private func edit(original: Profile, address raw: String, key: String) async -> String? {
        guard !busy else { return "连接进行中，请稍后再试" }
        let endpoint: Endpoint
        do {
            endpoint = try Endpoint.parse(raw, defaultUser: "root")
        } catch {
            return parseMessage(error)
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        // 地址与密钥都没变就不算一次编辑：直接关弹窗，不落盘、不断开、不动状态文案。
        // 点开看一眼又保存是常见动作，不该因此把连接断掉。放在格式闸之前，空保存
        // 不会被已存密钥的格式绊住。
        if endpoint == original.endpoint, trimmedKey == original.privateKeyPEM {
            return nil
        }

        guard trimmedKey.hasPrefix("-----BEGIN") else {
            return "私钥需以 -----BEGIN 开头，整份粘贴 OpenSSH 私钥"
        }

        // 只有「另一台」占着这个地址才算重名；被编辑的这台自己不算。
        if profiles.contains(where: { $0.endpoint == endpoint && $0.endpoint != original.endpoint }) {
            return "该主机已存在"
        }

        // 与 add(address:key:) 同一道门：改已存主机的密钥要先认证，取消则整条不落盘。
        if original.privateKeyPEM != trimmedKey {
            guard await SensitiveGate.shared.authenticate(reason: "替换 SSH 密钥") else {
                return "已取消替换"
            }
        }

        var profile = original
        profile.user = endpoint.user
        profile.host = endpoint.host
        profile.port = endpoint.port
        profile.privateKeyPEM = trimmedKey

        var updated = profiles
        if endpoint == original.endpoint, let index = updated.firstIndex(where: { $0.endpoint == original.endpoint }) {
            // 地址没变：原地更新，位置也不动。
            updated[index] = profile
        } else {
            // 地址变了：先摘掉旧条目再写新条目，列表里不留旧的一条。
            updated.removeAll { $0.endpoint == original.endpoint }
            if let index = updated.firstIndex(where: { $0.endpoint == endpoint }) {
                updated[index] = profile
            } else {
                updated.append(profile)
            }
        }
        // saveAll 不返回列表（返回 [Profile] 的是 upsert）：落盘与赋值分两步。
        // 落盘失败就整条不生效：不改内存列表、不断开、不关弹窗，错误回到表单上。
        do {
            try store.saveAll(updated)
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
        profiles = updated

        if savedProfile?.address == original.address {
            // 编辑的是当前这台：连接里的地址/密钥已经过期，断开等重连。
            if let live = transport {
                SensitiveGate.shared.sessionEnded()
                transport = nil
                Task { await live.close() }
            }
            // 降级态同理：那条 SSH 用的还是旧地址／旧密钥，一并放掉。
            dropDegradedSession()
            summary = nil
            showSessions = false
            select(profile)
            setStatus("主机信息已保存，请重新连接")
        } else {
            setStatus("已更新 \(profile.address)")
        }
        return nil
    }

    private func parseMessage(_ error: Error) -> String {
        guard let parseError = error as? Endpoint.ParseError else { return String(describing: error) }
        switch parseError {
        case .emptyUser: return "用户名不能为空"
        case .emptyHost: return "主机名不能为空"
        case .badPort: return "端口需在 1–65535 之间"
        case .missingHost: return "请输入主机地址，如 root@example.com:22"
        }
    }

    private func remove(_ profile: Profile) {
        guard !busy else { return }
        profiles = (try? store.remove(profile)) ?? profiles.filter { $0.address != profile.address }
        if savedProfile?.address == profile.address {
            savedProfile = nil
            address = ""
            keyText = ""
        }
        setStatus("已删除 \(profile.address)")
    }

    /// 编辑弹窗里的「清除密钥」落点：把这一台的私钥从档案里抹掉（认证在弹窗那边先过）。
    ///
    /// 只清 `privateKeyPEM`，地址与已信任的主机指纹都留着；清的是当前选中的这台时，
    /// 选中项与草稿密钥一起清空——否则下次 `connect()` 成功后的 `saveProfile` 会把
    /// 刚抹掉的密钥写回档案。连接不动：要断请走「编辑」的保存或「重新连接」。
    private func clearStoredKey(_ original: Profile) {
        var updated = profiles
        guard let index = updated.firstIndex(where: { $0.endpoint == original.endpoint }) else { return }
        updated[index].privateKeyPEM = ""
        try? store.saveAll(updated)
        profiles = updated
        if savedProfile?.address == original.address {
            savedProfile = updated[index]
            keyText = ""
        }
        setStatus("已清除 \(original.address) 的密钥")
    }

    private func saveProfile(endpoint: Endpoint, keyText: String, hosts: KnownHosts) {
        let profile = Profile(
            user: endpoint.user,
            host: endpoint.host,
            port: endpoint.port,
            privateKeyPEM: keyText,
            knownHosts: hosts.rawEntries
        )
        profiles = (try? store.upsert(profile)) ?? profiles
        savedProfile = profile
    }

    /// 放掉降级会话（换主机、编辑当前主机时用）：关 SSH、清自救终端与降级事实。
    /// 不 await——与放掉 `transport` 的写法一致：视图状态先摘，连接在后台收。
    /// 「断开连接」那条路走 `disconnect()`（它 await，并且写状态文案）。
    @MainActor
    private func dropDegradedSession() {
        guard let stale = degradedSession else { return }
        degradedSession = nil
        degraded = nil
        shellSession = nil
        showShell = false
        Task { await stale.close() }
    }

    /// 第一次真连上时问一次本地通知权限：UserDefaults 记「问过」，拒绝后也不再弹。
    /// 返回值刻意丢掉——没授权就到此为止，不降级、不报错。
    @MainActor
    private func askNotificationPermissionOnce() async {
        let key = "localNotification.permissionAsked"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        _ = await notifier?.requestPermission()
    }

    /// 把一条 dsh 已就绪的会话装成传输层：建 `DshTransport`、按开关接远程日志、连 mux。
    ///
    /// 失败时把刚建的那条收干净再抛（`close()` 连 SSH 一起关：这条会话已被这次尝试消耗，
    /// 留着也没人用）。成功后才交给界面并过安全闸门的会话标记。
    @MainActor
    private func installTransport(_ session: DshSession) async throws {
        let transport = DshTransport(session: session)
        do {
            if UserDefaults.standard.bool(forKey: "debug.remoteLog") {
                RemoteLog.shared.attach { command in
                    _ = try? await session.runRemote(command)
                }
            }
            try await transport.connect()
        } catch {
            await transport.close()
            throw error
        }
        self.transport = transport
        SensitiveGate.shared.sessionStarted()
        // 到这一拍才算真连上：问一次通知权限（接入前已经问过就不再弹）。
        await askNotificationPermissionOnce()
    }

    private func connect() async {
        // 连接要等数秒：先把这次要连的地址与私钥定成快照，之后一律读快照，
        // 免得期间换了选中项，把另一台的私钥写进这台档案。
        let snapshotAddress = address
        let snapshotKey = keyText
        guard await SensitiveGate.shared.authenticate(reason: "连接 dsh 主机") else { return }
        // 重连就是换一条新会话：先把旧的关掉，免得点一次多悬一条（写法同 select(_:)）。
        if let live = transport {
            SensitiveGate.shared.sessionEnded()
            transport = nil
            await live.close()
        }
        // 降级会话同样是一条活的 SSH：重连前一起收干净，别让两条并存。
        if let stale = degradedSession {
            degradedSession = nil
            degraded = nil
            shellSession = nil
            showShell = false
            await stale.close()
        }
        busy = true
        errorText = nil
        summary = nil
        defer { busy = false }

        do {
            let endpoint = try Endpoint.parse(snapshotAddress, defaultUser: "root")
            let key = try SSHKey.loadEd25519(snapshotKey)
            let savedHosts = profiles.first { $0.endpoint == endpoint }?.hosts ?? KnownHosts()
            // 退化路径①：SSH 也连不上时 `openDegrading` 照旧抛错（连接已收，没有可自救的东西），
            // 落到下面的 catch，界面回到「可重试连接」的现状。
            let opened = try await DshSession.openDegrading(
                endpoint: endpoint,
                key: key,
                knownHosts: savedHosts,
                fetcher: URLSessionFetcher(timeout: 6),
                onStage: { stage in
                    Diagnostics.shared.log(.info, "连接", String(describing: stage))
                    switch stage {
                    case .connecting: setStatus("连接 SSH…")
                    case .forwarding(let port): setStatus("隧道已建立 127.0.0.1:\(port)")
                    case .authenticating: setStatus("正在鉴权…")
                    case .ready: setStatus("已就绪")
                    }
                },
                onHostKey: { decision in
                    if case .firstContact(let fingerprint) = decision {
                        setStatus("首次连接，已记录主机指纹 \(fingerprint)")
                    }
                },
                onAttempt: { line in Diagnostics.shared.log(.info, "连接", line) }
            )
            // 首次连接会 TOFU 记一条主机指纹：降级回来也要落盘，下次才不会又当首次；
            // 降级态的 `restart()` 拿不到返回值，界面从 `knownHostsSnapshot` 补（见 retryDsh）。
            saveProfile(endpoint: endpoint, keyText: snapshotKey, hosts: opened.knownHosts)

            if let reason = opened.session.degraded {
                // dsh 未就绪：**不建** `DshTransport`——降级会话的 `localPort` 是 0 或旧值、
                // 凭据为空，建 mux/WebSocket 只会挂到超时。把「SSH 已连」这条事实留在界面上，
                // 两个自救动作（打开 SSH 终端／重试 dsh）由状态节里那组按钮给。
                degradedSession = opened.session
                degraded = reason
                summary = nil
                setStatus("SSH 已连，dsh 未就绪")
                Diagnostics.shared.log(.warn, "连接", "降级：\(reason.message)")
                return
            }

            summary = "隧道端口 \(opened.session.localPort)"
            setStatus("已连上 \(endpoint.user)@\(endpoint.host)")
            try await installTransport(opened.session)
            showSessions = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            setStatus("失败")
        }
    }

    /// 降级态的「打开 SSH 终端」：在同一条 SSH 上开一条交互 shell，全屏 sheet 显示。
    ///
    /// 先跑一条 `true` 探活再进终端页（退化路径②）：后台挂起后回来，SSH 常已被系统掐断，
    /// 这时把人丢进一个注定失败的终端页没有意义——直接提示「SSH 连接已断」、清掉降级态，
    /// 「重新连接」随即可点，也不 crash。
    @MainActor
    private func openShell() async {
        guard let session = degradedSession, !retrying, !openingShell else { return }
        openingShell = true
        defer { openingShell = false }
        do {
            _ = try await session.runRemote("true")
        } catch {
            Diagnostics.shared.log(.warn, "连接", "开 shell 前探活失败：\(DshBoard.message(error))")
            await dropDegraded(message: "SSH 连接已断，请重新连接")
            return
        }
        // 复用同一个 `TerminalSession`：收起 sheet 不关 shell，再点「打开 SSH 终端」回到同一条会话。
        if shellSession == nil {
            shellSession = TerminalSession(
                open: { cols, rows in try await session.openShell(cols: cols, rows: rows) },
                retry: { try await session.retryDsh() }
            )
        }
        showShell = true
    }

    /// 降级态的「重试 dsh」：复用同一条 SSH 重跑 dsh 链路。
    ///
    /// 阶段与结果由 Core 打日志（「复用 SSH 重试 dsh：<阶段>」），这里只打入口那一行。
    /// 三条出口：
    /// - 成功 → 已知主机表回写档案、建传输层，可以进会话；
    /// - `.sshUnavailable` / `.notConnected`（退化路径②）→ SSH 已断，提示并清掉降级态，回到未连接；
    /// - `.dshNotReady`（连试连败）→ 停在降级态，消息更新为最新的原因。
    @MainActor
    private func retryDsh() async {
        guard let session = degradedSession, !retrying, !openingShell else { return }
        retrying = true
        defer { retrying = false }
        errorText = nil
        Diagnostics.shared.log(.info, "连接", "用户重试 dsh")
        do {
            try await session.retryDsh()
            try await installTransport(session)
        } catch let error as DshSessionError {
            switch error {
            case .dshNotReady(let value):
                // 连续失败：停在降级态，只把消息换成新原因（连接还在，仍可开 shell 自救）。
                degraded = value
                setStatus("SSH 已连，dsh 仍未就绪")
                Diagnostics.shared.log(.warn, "连接", "降级：\(value.message)")
            case .sshUnavailable(let reason):
                Diagnostics.shared.log(.warn, "连接", "SSH 不可用：\(reason)")
                await dropDegraded(message: "SSH 连接已断，请重新连接")
            case .notConnected:
                await dropDegraded(message: "SSH 连接已断，请重新连接")
            }
            return
        } catch {
            // dsh 起来了但 mux 连不上：`installTransport` 已把这条会话关掉，没有可自救的连接了。
            await dropDegraded(message: DshBoard.message(error))
            return
        }
        // 成功：dsh 已就绪，降级态收摊。
        degraded = nil
        degradedSession = nil
        summary = "隧道端口 \(session.localPort)"
        setStatus("已就绪，可以进入会话")
        // 降级期间 `restart()` 抛错、拿不到已知主机表：从会话快照补写回档案。
        if let saved = savedProfile, saved.endpoint == session.endpoint {
            saveProfile(endpoint: session.endpoint, keyText: saved.privateKeyPEM, hosts: session.knownHostsSnapshot)
        }
    }

    /// 降级态收尾：把那条 SSH 真的关掉（`DshSession.close()` 覆盖降级态：转发与连接一起收），
    /// 会话、自救终端与降级事实一并清掉，回到「可重新连接」的未连接态。
    /// `message` 非 nil 时作为错误条上屏（如「SSH 连接已断，请重新连接」）。
    @MainActor
    private func dropDegraded(message: String? = nil) async {
        let session = degradedSession
        degradedSession = nil
        degraded = nil
        shellSession = nil
        showShell = false
        summary = nil
        if let message {
            errorText = message
            setStatus("未连接")
        }
        // 退化路径④：降级态被断开也要收干净，不泄漏连接。
        await session?.close()
    }

    /// 状态节的「断开连接」：放掉当前连接，回到「可重新连接」的状态。
    ///
    /// 顺序照连接建立的反向：先摘掉视图持有的连接（按钮与「进入会话」随之为空），
    /// 再收安全闸门的会话标记与远程日志的 sink，最后关 SSH／转发／WebSocket。
    /// 降级态没有 `DshTransport`，但有一条活的 SSH：照样要真的关掉它
    /// （退化路径④：关 App／断开都不泄漏连接）。地址与私钥原样留着，所以「重新连接」不用重敲。
    private func disconnect() async {
        shellSession = nil
        showShell = false
        summary = nil
        errorText = nil
        if let live = transport {
            transport = nil
            showSessions = false
            SensitiveGate.shared.sessionEnded()
            RemoteLog.shared.detach()
            await live.close()
            setStatus("已断开（可重新连接）")
            return
        }
        guard degradedSession != nil else { return }
        await dropDegraded()
        SensitiveGate.shared.sessionEnded()
        setStatus("已断开（可重新连接）")
    }
}

/// 工具栏 `+` 与行内左滑「编辑」共用的主机编辑页：主机地址 + ed25519 私钥一起收，
/// 解析、校验与落盘交给调用方（新增进 `add(address:key:)`，编辑进 `edit(original:address:key:)`）。
///
/// 这是导航栈里推入的一页，不自带 `NavigationStack`；出口只有工具栏的「取消」与
/// 「保存」，返回按钮藏起来（`navigationBarBackButtonHidden`），免得手滑的边缘返回
/// 把刚敲的内容带走。地址或密钥动过时，「取消」先问一句再退。
///
/// 两栏、可提交判定、错误条与 `submitting` 只有一份；两种模式只差标题、确认按钮
/// 与预填的初值。编辑模式额外多一个「清除密钥」的 destructive 入口（原先在独立的
/// 密钥页上），它不经过表单提交，也不受「两栏非空」那条规则约束。
private struct HostEditorPage: View {
    enum Mode {
        /// 工具栏 `+`：空表单，提交后新加一台。
        case add
        /// 行内左滑「编辑」：用这一台的地址与私钥预填，提交后替换这一台。
        case edit(Profile)
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    /// 地址与私钥一起交回；返回错误文案，`nil` 表示已落盘，可以退回上一页。
    /// `async` 是因为覆盖已存主机的密钥要先过 `SensitiveGate`；`@MainActor` 与
    /// 调用方（本页与 `add`／`edit` 都在主线程）对齐，不丢全局 actor。
    let onSubmit: @MainActor (String, String) async -> String?

    /// 编辑模式的「清除密钥」落点（把这一台的 `privateKeyPEM` 抹掉并落盘）；新增模式传 `nil`。
    /// 认证由本页先过，这里只在通过后被调用一次。
    let onClearKey: (@MainActor () -> Void)?

    @State private var text: String
    @State private var key: String
    @State private var error: String?
    @State private var submitting = false
    @State private var confirmingDiscard = false

    /// 推入这一页那一刻的地址与密钥；「取消」拿它判断有没有改过。
    private let seedAddress: String
    private let seedKey: String

    /// 编辑模式把这一台的地址与密钥填进表单；新增模式留空。
    init(
        mode: Mode,
        onSubmit: @escaping @MainActor (String, String) async -> String?,
        onClearKey: (@MainActor () -> Void)? = nil
    ) {
        self.mode = mode
        self.onSubmit = onSubmit
        self.onClearKey = onClearKey
        let seed: Profile?
        if case .edit(let profile) = mode { seed = profile } else { seed = nil }
        let address = seed?.address ?? ""
        let storedKey = seed?.privateKeyPEM ?? ""
        seedAddress = address
        seedKey = storedKey
        _text = State(initialValue: address)
        _key = State(initialValue: storedKey)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// 这一台档案里还有密钥才给「清除密钥」，已清空的不再露一个空按钮。
    private var hasStoredKey: Bool {
        if case .edit(let profile) = mode { return !profile.privateKeyPEM.isEmpty }
        return false
    }

    private var pageTitle: String { isEditing ? "编辑主机" : "添加主机" }

    private var confirmTitle: String {
        let base = isEditing ? "保存" : "添加"
        return submitting ? "\(base)中…" : base
    }

    var body: some View {
        Form {
            Section {
                TextField("user@host:port", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("主机地址")
            } footer: {
                Text("形如 root@example.com:22；省略用户按 root，省略端口按 22。")
            }

            Section {
                TextEditor(text: $key)
                    .frame(minHeight: 140)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("ed25519 私钥")
            } footer: {
                Text("整份粘贴 OpenSSH 私钥文件（以 OPENSSH PRIVATE KEY 开头）。明文存在本机容器，界面只显示指纹。")
            }

            if let error {
                Section {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            // 清除是独立动作：不读表单两栏，也不占「保存」那条路。
            if hasStoredKey, let onClearKey {
                Section {
                    Button("清除密钥", role: .destructive) { clear() }
                        .disabled(submitting)
                } footer: {
                    Text("把这一台已存的私钥从本机容器里抹掉，需要认证。清除后要重新粘贴私钥才能连接；只改地址或换密钥请用右上角「保存」。")
                }
            }
        }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        // 出口只留工具栏两个：藏掉返回按钮，挡一下边缘返回手势误丢输入。
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmTitle) { submit() }
                    .disabled(submitting || !canSubmit)
            }
        }
        .confirmationDialog("放弃修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    /// 两栏都非空才让点「添加」／「保存」；地址与密钥的格式判定留在调用方，
    /// 报错回到这里的 `error` 上显示。
    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 有没有改过：地址按解析后的 `Endpoint` 比（把 `example.com` 补成
    /// `root@example.com:22` 不算改），密钥按去空白后的串比。地址被敲成解析不了的
    /// 样子也算改过——用户确实动了这一栏。
    private var isDirty: Bool {
        if key.trimmingCharacters(in: .whitespacesAndNewlines)
            != seedKey.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = try? Endpoint.parse(typed, defaultUser: "root"),
           let seed = try? Endpoint.parse(seedAddress, defaultUser: "root") {
            return current != seed
        }
        return typed != seedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「取消」只有一个入口：改过先问一句，没改直接退。
    private func cancel() {
        if isDirty {
            confirmingDiscard = true
        } else {
            dismiss()
        }
    }

    /// 清除只走自己的门：认证不过什么都不做，停在这一页；通过才落盘并退回列表。
    /// `submitting` 挡住与「保存」并发点，也算禁用重复点。
    private func clear() {
        guard !submitting, let onClearKey else { return }
        submitting = true
        Task {
            defer { submitting = false }
            guard await SensitiveGate.shared.authenticate(reason: "清除 SSH 密钥") else { return }
            onClearKey()
            dismiss()
        }
    }

    /// `Task` 继承 View 的 MainActor 上下文，`error` 与 `dismiss` 都在主线程上改。
    /// `submitting` 挡连点：认证没回来时再点一次会排第二个 Task，可能连弹两次认证。
    private func submit() {
        guard !submitting else { return }
        submitting = true
        Task {
            defer { submitting = false }
            if let message = await onSubmit(text, key) {
                error = message
            } else {
                dismiss()
            }
        }
    }
}

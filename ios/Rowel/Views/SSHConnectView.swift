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

    @State private var address = ""
    @State private var keyText = ""
    @State private var status = "未连接"
    @State private var errorText: String?
    @State private var busy = false
    @State private var summary: String?
    @State private var transport: DshTransport?
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
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) {
                                    Task {
                                        guard await SensitiveGate.shared.authenticate(reason: "删除已保存的主机") else { return }
                                        remove(profile)
                                    }
                                }
                                // 编辑与工具栏 `+` 是同一个表单，编辑的就是这一行代表的这一台。
                                Button("编辑") { hostEditor = .edit(profile) }
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
                    // 两个入口并排：左「重新连接」（未连接时不可点）、右「进入会话」。
                    HStack(spacing: 12) {
                        Button {
                            Task { await connect() }
                        } label: {
                            Text("重新连接")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy || transport == nil || address.isEmpty || keyText.isEmpty)

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
                        .disabled(busy || (transport == nil && (address.isEmpty || keyText.isEmpty)))
                    }
                }
            }
            .navigationDestination(isPresented: $showSessions) {
                if let transport {
                    DshSessionListView(transport: transport)
                }
            }
            .task { loadProfiles() }
            .navigationTitle("连接 dsh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
        guard transport == nil else { return "进入会话" }
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
        // 换到别的主机就把旧连接放掉，免得「进入会话」进的是上一台。
        if let live = transport, live.dshSession.endpoint != profile.endpoint {
            transport = nil
            Task { await live.dshSession.close() }
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
        if let saved = try? store.upsert(profile) {
            profiles = saved
        } else if let index = profiles.firstIndex(where: { $0.endpoint == endpoint }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
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
        try? store.saveAll(updated)
        profiles = updated

        if savedProfile?.address == original.address {
            // 编辑的是当前这台：连接里的地址/密钥已经过期，断开等重连。
            if let live = transport {
                transport = nil
                Task { await live.dshSession.close() }
            }
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

    private func connect() async {
        guard await SensitiveGate.shared.authenticate(reason: "连接 dsh 主机") else { return }
        // 重连就是换一条新会话：先把旧的关掉，免得点一次多悬一条（写法同 select(_:)）。
        if let live = transport {
            transport = nil
            await live.dshSession.close()
        }
        busy = true
        errorText = nil
        summary = nil
        defer { busy = false }

        do {
            let endpoint = try Endpoint.parse(address, defaultUser: "root")
            let key = try SSHKey.loadEd25519(keyText)
            let savedHosts = profiles.first { $0.endpoint == endpoint }?.hosts ?? KnownHosts()
            let opened = try await DshSession.open(
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
            summary = "隧道端口 \(opened.session.localPort)"
            setStatus("已连上 \(endpoint.user)@\(endpoint.host)")

            saveProfile(endpoint: endpoint, keyText: keyText, hosts: opened.knownHosts)

            let transport = DshTransport(session: opened.session)
            if UserDefaults.standard.bool(forKey: "debug.remoteLog") {
                RemoteLog.shared.attach { command in
                    _ = try? await opened.session.runRemote(command)
                }
            }
            try await transport.connect()
            self.transport = transport
            SensitiveGate.shared.sessionStarted()
            showSessions = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            setStatus("失败")
        }
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

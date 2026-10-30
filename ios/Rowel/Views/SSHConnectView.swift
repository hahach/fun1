import SwiftUI
import DshClientCore

/// T2 的入口：SSH 主机表单 + 已保存的主机列表。
///
/// 多主机：档案按 `user@host:port` 去重存在 `profiles.json`，旧的单档案 `profile.json`
/// 照样读得到（首次升级不会丢连接）。密钥明文存盘，界面只显示指纹；替换/清除/删除需认证。
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
    @State private var editingKey = false
    @State private var showSessions = false

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
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    Task {
                                        guard await SensitiveGate.shared.authenticate(reason: "删除已保存的主机") else { return }
                                        remove(profile)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("主机") {
                    TextField("user@host:port", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }

                Section {
                    if let savedProfile, !savedProfile.privateKeyPEM.isEmpty, !editingKey {
                        Text(SSHKey.fingerprint(of: savedProfile.privateKeyPEM).map { "ed25519 · \($0)" } ?? "已保存的密钥")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("替换密钥") {
                            Task {
                                guard await SensitiveGate.shared.authenticate(reason: "替换 SSH 密钥") else { return }
                                editingKey = true
                                keyText = savedProfile.privateKeyPEM
                            }
                        }
                        Button("清除密钥", role: .destructive) {
                            Task {
                                guard await SensitiveGate.shared.authenticate(reason: "清除 SSH 密钥") else { return }
                                clearSavedKey()
                            }
                        }
                    } else {
                        TextEditor(text: $keyText)
                            .frame(minHeight: 140)
                            .font(.system(.caption, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("ed25519 私钥")
                } footer: {
                    Text(editingKey || savedProfile == nil || savedProfile?.privateKeyPEM.isEmpty == true
                         ? "整份粘贴 OpenSSH 私钥文件（以 OPENSSH PRIVATE KEY 开头）。保存后界面只显示指纹。"
                         : "密钥已保存在本机容器；替换或清除需要认证。")
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
                }

                Section {
                    if let transport {
                        Button("进入会话") { showSessions = true }
                        Button("重新连接") { Task { await connect() } }
                            .disabled(busy || address.isEmpty || keyText.isEmpty)
                    } else {
                        Button(busy ? "连接中…" : "连接") {
                            Task { await connect() }
                        }
                        .disabled(busy || address.isEmpty || keyText.isEmpty)
                    }
                } footer: {
                    if let transport {
                        Text("已连到 \(transport.dshSession.endpoint.user)@\(transport.dshSession.endpoint.host)，直接进入即可；换主机才需要重连。")
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
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
        editingKey = false
    }

    private func remove(_ profile: Profile) {
        profiles = (try? store.remove(profile)) ?? profiles.filter { $0.address != profile.address }
        if savedProfile?.address == profile.address {
            savedProfile = nil
            address = ""
            keyText = ""
            editingKey = false
        }
        setStatus("已删除 \(profile.address)")
    }

    private func clearSavedKey() {
        guard var profile = savedProfile else { return }
        profile.privateKeyPEM = ""
        profiles = (try? store.upsert(profile)) ?? profiles
        savedProfile = profile
        keyText = ""
        editingKey = false
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
        editingKey = false
    }

    private func connect() async {
        guard await SensitiveGate.shared.authenticate(reason: "连接 dsh 主机") else { return }
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
                    case .authenticating: setStatus("取 token、换 cookie…")
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
            summary = "隧道端口 \(opened.session.localPort) · cookie \(opened.session.credentials.cookieName)"
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
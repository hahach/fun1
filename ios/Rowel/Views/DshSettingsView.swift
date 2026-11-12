import SwiftUI
import DshClientCore

/// 设置：连接的实体信息、安全闸门的空闲阈值、诊断入口，以及本构建的编号。
///
/// 未连接时也进得来（连接页右上角的齿轮）：`transport` 与 `board` 都可能是 `nil`，
/// 「连接」节、重建入口与连接错误随之缺席，其余设置照常可用。
struct DshSettingsView: View {
    let transport: DshTransport?
    let board: DshBoard?
    @AppStorage("security.idleSeconds") private var idleSeconds: Double = 60
    @State private var busy = false
    @AppStorage("debug.remoteLog") private var remoteLog = false
    /// 跨端草稿同步：关掉后会话页连控制器都不建，一条 draft/* 都不发。
    @AppStorage("draft.syncEnabled") private var draftSyncEnabled = true
    /// 启动／离开后的锁。它自己写 UserDefaults，这里只提供入口。
    @Environment(AppLock.self) private var appLock

    var body: some View {
        // `AppLock` 以 `@Observable` 从环境注入，绑定要过一次 `Bindable`。
        @Bindable var appLock = appLock
        Form {
            if let transport = transport, let endpoint = endpoint {
                Section("连接") {
                    LabeledContent("主机", value: "\(endpoint.user)@\(endpoint.host):\(endpoint.port)")
                    LabeledContent("本地转发端口", value: String(transport.dshSession.localPort))
                }
            }

            Section {
                Toggle("跨端草稿同步", isOn: $draftSyncEnabled)
            } header: {
                Text("草稿")
            } footer: {
                Text("草稿在会话页自动与主机同步，换设备接着写。关掉即回到纯本地：草稿只存在这台手机上，不再与服务端同步。")
            }

            Section {
                Stepper(value: $idleSeconds, in: 0...600, step: 30) {
                    LabeledContent("回前台需验证", value: idleSeconds < 1 ? "每次" : "\(Int(idleSeconds)) 秒后")
                }
            } header: {
                Text("安全")
            } footer: {
                Text("会话在后台超过这个时长，回到前台要先过系统认证；0 表示每次都验。")
            }

            Section {
                Toggle("启动与离开后锁定", isOn: $appLock.isEnabled)
                Picker("离开多久后锁定", selection: $appLock.delay) {
                    ForEach(LockDelay.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("开启后，App 冷启动与离开超过所选时长都要求面容／密码。连接主机、替换密钥的验证与此独立。")
            }

            Section {
                Text("SSH 私钥明文存于 App 沙盒，界面只显示指纹；替换或清除需要认证。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    DshDiagnosticsView()
                } label: {
                    Label("诊断与日志（可复制）", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink {
                    DshSelectionProbeView()
                } label: {
                    Label("选区自检（四种写法对照）", systemImage: "selection.pin.in.out")
                }
                Toggle("调试日志写到主机（.tmp/ios-app/logs）", isOn: $remoteLog)
                    .font(.callout)
                    .onChange(of: remoteLog) { _, enabled in
                        guard enabled else {
                            RemoteLog.shared.detach()
                            return
                        }
                        // 未连接时只留开关本身（`@AppStorage` 已落盘），不 attach；连接后由连接页按开关接上。
                        guard let transport = transport else { return }
                        RemoteLog.shared.attach { command in
                            _ = try? await transport.runRemote(command)
                        }
                        Diagnostics.shared.log(.info, "调试", "远程日志已开启")
                        Task { await RemoteLog.shared.flush() }
                    }
                if transport != nil, board != nil {
                    Button(busy ? "重建中…" : "重建连接（SSH、转发、凭据）") {
                        Task { await rebuilt() }
                    }
                    .disabled(busy)
                }
                if let errorText = board?.errorText {
                    Text(errorText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("诊断")
            } footer: {
                if transport == nil {
                    Text("未连接时开启，连接后生效")
                }
            }

            Section {
                LabeledContent("客户端", value: ClientIdentity.buildStamp)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var endpoint: Endpoint? { transport?.dshSession.endpoint }

    private func rebuilt() async {
        guard let transport = transport, let board = board else { return }
        busy = true
        defer { busy = false }
        do {
            try await transport.refresh(trigger: "设置页手动")
            board.startWorkspaces()
            await board.load()
            board.startEvents()
        } catch {
            board.report(error)
        }
    }
}

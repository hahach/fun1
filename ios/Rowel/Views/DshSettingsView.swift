import SwiftUI
import DshClientCore

/// 设置：连接的实体信息、安全闸门的空闲阈值、诊断入口，以及本构建的编号。
struct DshSettingsView: View {
    let transport: DshTransport
    @ObservedObject var board: DshBoard
    @AppStorage("security.idleSeconds") private var idleSeconds: Double = 60
    @State private var busy = false

    var body: some View {
        Form {
            Section("连接") {
                LabeledContent("主机", value: "\(endpoint.user)@\(endpoint.host):\(endpoint.port)")
                LabeledContent("本地转发端口", value: String(transport.dshSession.localPort))
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
                Text("SSH 私钥明文存于 App 沙盒，界面只显示指纹；替换或清除需要认证。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("诊断") {
                NavigationLink {
                    DshDiagnosticsView()
                } label: {
                    Label("诊断与日志（可复制）", systemImage: "doc.text.magnifyingglass")
                }
                Button(busy ? "重建中…" : "重建连接（SSH、转发、凭据）") {
                    Task { await rebuilt() }
                }
                .disabled(busy)
                if let errorText = board.errorText {
                    Text(errorText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                LabeledContent("客户端", value: ClientIdentity.buildStamp)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var endpoint: Endpoint { transport.dshSession.endpoint }

    private func rebuilt() async {
        busy = true
        defer { busy = false }
        do {
            try await transport.refresh()
            board.startWorkspaces()
            await board.load()
            board.startEvents()
        } catch {
            board.report(error)
        }
    }
}


import SwiftUI
import DshClientCore

/// 新建会话：只从**已有工作区**里选，再挑预设。
///
/// 移动端不新建工作区、也不浏览目录：工作区顺序直接沿用桌面侧拖出来的顺序
/// （`workspace/follow` 的 baseline 数组顺序 + `order` 增量）。
struct DshNewSessionView: View {
    let transport: DshTransport
    @ObservedObject var board: DshBoard
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var presets: [AgentPreset] = []
    @State private var preset: String?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("工作区") {
                    if board.workspaces.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在读取工作区…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(board.workspaces) { workspace in
                        Button {
                            Task { await create(cwd: workspace.path, workspaceId: workspace.id) }
                        } label: {
                            row(workspace.displayTitle, workspace.path)
                        }
                        .disabled(busy)
                    }
                }

                Section("预设") {
                    if presets.isEmpty {
                        Text("用机器默认预设")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("预设", selection: $preset) {
                            Text("机器默认").tag(String?.none)
                            ForEach(presets) { item in
                                Text(item.name).tag(String?.some(item.id))
                            }
                        }
                    }
                }

                if let problem {
                    Section {
                        Text(problem)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") {
                        board.restartWorkspaces()
                        Task { await loadPresets() }
                    }
                }
            }
            .task {
                // 首次打开可能还没读到工作区：这里补一次，别让弹窗看起来是空白。
                board.restartWorkspaces()
                await loadPresets()
            }
        }
    }

    private func row(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadPresets() async {
        presets = (try? await Harness(transport: transport).presets()) ?? []
    }

    private func create(cwd: String?, workspaceId: String?) async {
        busy = true
        defer { busy = false }
        do {
            // `workspaceId` 与 `cwd` 互斥（dsh 明文规定），二选一传。
            let id = try await Harness(transport: transport).createSession(
                cwd: workspaceId == nil ? cwd : nil,
                workspaceId: workspaceId,
                agentPreset: preset,
                sessionId: board.blankSession(inWorkspacePath: cwd)
            )
            onCreated(id)
            dismiss()
        } catch {
            problem = DshBoard.message(error)
        }
    }
}


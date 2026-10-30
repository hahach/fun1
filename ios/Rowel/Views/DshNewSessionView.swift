import SwiftUI
import DshClientCore

/// 新建会话：只从**已有工作区**里选，再挑预设。
///
/// 移动端不新建工作区、也不浏览目录：工作区顺序直接沿用桌面侧拖出来的顺序
/// （`workspace/follow` 的 baseline 数组顺序 + `order` 增量）。
struct DshNewSessionView: View {
    let transport: DshTransport
    @ObservedObject var board: DshBoard
    let onCreated: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var presets: [AgentPreset] = []
    @State private var preset: String?
    @State private var busy = false
    /// 新会话的模型：nil 表示沿用机器默认（＝主机保存的上一次主动切换）。
    @State private var catalog: ModelCatalog?
    @State private var machineDefault: ModelOption?
    @State private var chosen: ModelOption?
    /// 权限预设与机器的默认值：新建会话也要能选（B-150）。nil 表示沿用机器默认。
    @State private var permissions: [PermissionChoice.Option] = []
    @State private var permissionDefault: PermissionChoice?
    @State private var permission: String?
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

                Section("模型") {
                    Menu {
                        Button {
                            chosen = nil
                        } label: {
                            if chosen == nil {
                                Label(defaultModelLabel, systemImage: "checkmark")
                            } else {
                                Text(defaultModelLabel)
                            }
                        }
                        ForEach(providerGroups, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.options) { option in
                                    Button {
                                        chosen = option
                                    } label: {
                                        if option.id == chosen?.id {
                                            Label(option.name, systemImage: "checkmark")
                                        } else {
                                            Text(option.name)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("模型")
                            Spacer()
                            Text(chosen?.name ?? defaultModelLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(busy || catalog == nil)
                }

                Section("权限") {
                    Picker("权限", selection: $permission) {
                        Text(permissionDefaultLabel).tag(String?.none)
                        ForEach(permissions) { option in
                            Text(option.name).tag(String?.some(option.value))
                        }
                    }
                    .disabled(busy || permissions.isEmpty)
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
        let harness = Harness(transport: transport)
        presets = (try? await harness.presets()) ?? []
        if permissions.isEmpty, let catalog = try? await harness.permissionPresets() {
            permissions = catalog.options
            permissionDefault = catalog.defaults
        }
        guard catalog == nil else { return }
        catalog = try? await harness.machineModels()
        // 主机保存的「新会话默认」：session/modelCatalog 的 default 字段，
        // 与目录里的条目按 provider+model 对上，才拿得到可显示的名字。
        if let raw = try? await transport.call("session/modelCatalog", .emptyObject),
           let def = raw["default"],
           let provider = def["provider"]?.stringValue,
           let model = def["model"]?.stringValue {
            machineDefault = catalog?.options.first { $0.provider == provider && $0.model == model }
        }
    }

    private var providerGroups: [(name: String, options: [ModelOption])] {
        guard let catalog else { return [] }
        var order: [String] = []
        var buckets: [String: [ModelOption]] = [:]
        for option in catalog.options {
            if buckets[option.providerName] == nil { order.append(option.providerName) }
            buckets[option.providerName, default: []].append(option)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// 新会话实际会用的模型。机器把「上一次主动切换」当成新会话的默认，而目录里的
    /// `default` 是后台异步保存的、常常还落后一拍——所以本机记住的那次优先（B-149）。
    private var defaultModelLabel: String {
        if let remembered = ModelMemory.name { return "机器默认（\(remembered)）" }
        if let machineDefault { return "机器默认（\(machineDefault.name)）" }
        return "机器默认"
    }

    /// 权限的默认名字：机器默认预设叫什么就写什么，读不到才退回「机器默认」。
    private var permissionDefaultLabel: String {
        guard let preset = permissionDefault else { return "机器默认" }
        let name = preset.options.first(where: { $0.value == preset.current })?.name ?? preset.current
        return "机器默认（\(name)）"
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
            let harness = Harness(transport: transport)
            if let chosen {
                // dsh 的 session/create 不带模型；建完立刻切一次，效果等同 PC 的选择。
                try? await harness.selectModel(sessionId: id, option: chosen)
                ModelMemory.remember(chosen)
            }
            if let permission {
                // 权限同理：建完用 /permission 切一次。
                _ = try? await harness.command(sessionId: id, line: "/permission " + permission)
            }
            // 记下这台机器实际给了什么模型：界面标签永远是推断，日志里的才是事实（B-149）。
            if let actual = (try? await harness.models(sessionId: id))?.current {
                Diagnostics.shared.log(
                    .info, "新建会话",
                    "实际模型 \(actual.name)，界面 \(chosen?.name ?? defaultModelLabel)"
                )
            }
            onCreated(id, cwd)
            dismiss()
        } catch {
            problem = DshBoard.message(error)
        }
    }
}
import SwiftUI

/// 待发区：轮次进行中发出的消息先排在这里，轮次结束自动发出。
///
/// 每条右侧三个动作与桌面一致：编辑、删除、发送（＝立刻插进当前轮次）。
/// 「发送」只对还没进入当前轮次（`placement == "queued"`）且当前轮还在跑的条目出现——
/// 轮次已结束时服务端会回 `session/steer-unavailable`，按钮先不出现（B-132）。
struct DshQueuedBar: View {
    let items: [QueuedMessage]
    /// 当前轮是否还在跑：不在跑时「发送」没有意义，留着只会点出一个错误。
    var canSteer: Bool = true
    /// 这条是否已被机器列进 inbox。没列进之前它只有本机 requestId，
    /// 插话与删除都会被回 `queue-item-not-found`（B-145）。
    var isListed: (QueuedMessage) -> Bool = { _ in true }
    let onEdit: (QueuedMessage) -> Void
    let onRemove: (QueuedMessage) -> Void
    let onSteer: (QueuedMessage) -> Void

    /// 正按下的动作：落地（或超时）前同一行的按钮禁用，连点不会重复发。
    @State private var pending: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("待发 \(items.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.placement == "steering" ? "arrow.turn.up.right" : "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item.text.isEmpty ? "（图片）" : item.text)
                        .font(.footnote)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isListed(item) {
                        CapsuleAction(title: "编辑", tint: .secondary) { onEdit(item) }
                        CapsuleAction(title: "删除", tint: .red, busy: pending.contains(key(item, "remove"))) {
                            tap(item, "remove", onRemove)
                        }
                        if item.placement == "queued", canSteer {
                            CapsuleAction(title: "发送", tint: .accentColor, busy: pending.contains(key(item, "steer"))) {
                                tap(item, "steer", onSteer)
                            }
                        }
                    } else {
                        // 机器还没列出它：这会儿只有本机 id，动作一律不做，等投影回来。
                        Text("排队中…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 6)
        .onChange(of: items) { _, _ in
            // 投影换了：动作已在服务端落地，放开按钮。
            pending.removeAll()
        }
    }

    private func key(_ item: QueuedMessage, _ action: String) -> String { "\(item.id).\(action)" }

    /// 一次点按只发一次：重复点按记一条日志后丢弃，服务端不回执时 6 秒后自己放开。
    private func tap(_ item: QueuedMessage, _ action: String, _ run: @escaping (QueuedMessage) -> Void) {
        let slot = key(item, action)
        guard !pending.contains(slot) else {
            Diagnostics.shared.log(.info, "待发区", "\(action) 在处理中，忽略重复点按 item=\(item.id)")
            return
        }
        Diagnostics.shared.log(.info, "待发区", "\(action) 按下 item=\(item.id) placement=\(item.placement)")
        pending.insert(slot)
        run(item)
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            pending.remove(slot)
        }
    }
}

/// 待发区动作按钮：胶囊底＋同色文字，与输入框工具栏的胶囊一致。
private struct CapsuleAction: View {
    let title: String
    let tint: Color
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(tint.opacity(busy ? 0.06 : 0.14)))
                .foregroundStyle(tint.opacity(busy ? 0.4 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

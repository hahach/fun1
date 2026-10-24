import SwiftUI

/// 待发区：轮次进行中发出的消息先排在这里，轮次结束自动发出。
///
/// 每条右侧三个动作与桌面一致：编辑、删除、发送（＝立刻插进当前轮次）。
/// 「发送」只对还没进入当前轮次的（`placement == "queued"`）出现。
struct DshQueuedBar: View {
    let items: [QueuedMessage]
    let onEdit: (QueuedMessage) -> Void
    let onRemove: (QueuedMessage) -> Void
    let onSteer: (QueuedMessage) -> Void

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
                    Button("编辑") { onEdit(item) }
                    Button("删除") { onRemove(item) }
                        .foregroundStyle(.red)
                    if item.placement == "queued" {
                        Button("发送") { onSteer(item) }
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 6)
    }
}

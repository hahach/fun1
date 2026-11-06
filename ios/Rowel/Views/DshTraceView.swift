import SwiftUI

/// 轨迹：一行一个事件。
///
/// 转录是拿来「读」的，这张表是拿来「找」的：它刚才在干什么、哪一步出错了、
/// 那条命令在哪。信息密度大，所以默认全部、可切「只看工具 / 只看错误」，
/// 每行只留时间、类型和一句摘要；点一行跳回转录的对应位置。
struct DshTraceView: View {
    let conversation: Conversation
    let onJump: (String) -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case tools = "只看工具"
        case failures = "只看错误"

        var id: String { rawValue }
    }

    private struct Row: Identifiable {
        let id: String
        let at: Date
        let kind: String
        let text: String
        let failed: Bool
    }

    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all

    var body: some View {
        NavigationStack {
            List(rows) { row in
                Button {
                    onJump(row.id)
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(DshTraceView.stamp.string(from: row.at))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(row.kind)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Text(row.text)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(row.failed ? Color.red : Color.primary)
                    }
                }
            }
            .navigationTitle("轨迹（\(rows.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("筛选", selection: $filter) {
                        ForEach(Filter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var rows: [Row] {
        conversation.items.compactMap { item in
            switch item {
            case .user(let turn):
                guard filter == .all else { return nil }
                return Row(id: turn.id, at: turn.at, kind: "你", text: oneLine(turn.text), failed: false)
            case .assistant(let turn):
                guard filter == .all else { return nil }
                let body = turn.text.isEmpty ? turn.reasoning : turn.text
                return Row(id: turn.id, at: turn.at, kind: "答 \(turn.turn).\(turn.step)", text: oneLine(body), failed: false)
            case .tool(let card):
                if filter == .failures && !card.failed { return nil }
                let state = card.failed ? "失败" : (card.running ? "运行中" : "完成")
                return Row(id: card.id, at: card.at, kind: "工具", text: oneLine(card.headline) + " · " + state, failed: card.failed)
            case .notice(let notice):
                guard filter == .all else { return nil }
                return Row(id: notice.id, at: notice.at, kind: "提示", text: oneLine(notice.text), failed: notice.kind == .failure)
            }
        }
    }

    private func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}


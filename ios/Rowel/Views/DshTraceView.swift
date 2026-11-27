import SwiftUI

/// 轨迹：一行一个事件。
///
/// 转录是拿来「读」的，这张表是拿来「找」的：它刚才在干什么、哪一步出错了、
/// 那条命令在哪。信息密度大，所以默认全部、可切「只看工具 / 只看错误」，
/// 每行只留时间、类型和一句摘要；点一行跳回转录的对应位置。
struct DshTraceView: View {
    let conversation: Conversation
    let onJump: (String) -> Void
    /// 滑到底时拉一页更早的消息；由会话页传入，避开会话页自己的滚动持锁。
    var loadOlder: (() async -> Void)?

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
        let fullText: String
        let failed: Bool
    }

    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var expandedId: String?

    var body: some View {
        let list = rows
        NavigationStack {
            List {
                ForEach(list) { row in
                    Section {
                        // 点行只展开／收起；跳回会话由展开区里的按钮负责。
                        Button {
                            withAnimation { expandedId = (expandedId == row.id ? nil : row.id) }
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
                        if expandedId == row.id {
                            // 限高滚动，完整正文可选中／复制；再点行仍可收起。
                            ScrollView {
                                Text(row.fullText)
                                    .font(.system(size: 14))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 260)
                            Button("在会话中定位") {
                                dismiss()
                                onJump(row.id)
                            }
                        }
                    }
                }
                // 列表尾部的翻页触发点：出现一次拉一页，没有更多就不再出现。
                if conversation.hasMore, let loadOlder {
                    Section {
                        if conversation.loading {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Text("加载中…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        } else {
                            // 出现即触发一次；下一页回来又会重新出现，直到没有更多。
                            TraceLoadOlderTrigger { await loadOlder() }
                        }
                    }
                }
            }
            .navigationTitle("轨迹（\(list.count)）")
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
                return Row(id: turn.id, at: turn.at, kind: "你", text: oneLine(turn.text), fullText: turn.text, failed: false)
            case .assistant(let turn):
                guard filter == .all else { return nil }
                let body = turn.text.isEmpty ? turn.reasoning : turn.text
                return Row(id: turn.id, at: turn.at, kind: "答 \(turn.turn).\(turn.step)", text: oneLine(body), fullText: body, failed: false)
            case .tool(let card):
                if filter == .failures && !card.failed { return nil }
                let state = card.failed ? "失败" : (card.running ? "运行中" : "完成")
                // 展开区头尾都在：概览、原始参数与结果文本，不只取截断的 headline。
                var full = "工具 \(card.name) · \(state)\n\n" + card.headline
                if !card.arguments.isEmpty { full += "\n\n参数\n" + card.arguments }
                if let result = card.resultText, !result.isEmpty { full += "\n\n结果\n" + result }
                return Row(id: card.id, at: card.at, kind: "工具", text: oneLine(card.headline) + " · " + state, fullText: full, failed: card.failed)
            case .notice(let notice):
                guard filter == .all else { return nil }
                return Row(id: notice.id, at: notice.at, kind: "提示", text: oneLine(notice.text), fullText: notice.text, failed: notice.kind == .failure)
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

/// 列表尾部的触发器：只在一「出现」时拉一页，重复重建不再触发。
private struct TraceLoadOlderTrigger: View {
    let load: () async -> Void
    /// 同一实例只拉一页；加载态会换掉本视图，回来时是新实例、可再拉下一页。
    @State private var didFire = false

    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("加载更早的消息…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .task {
            guard !didFire else { return }
            didFire = true
            await load()
        }
    }
}


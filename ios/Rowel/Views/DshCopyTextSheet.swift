import SwiftUI
#if canImport(UIKit)
import UIKit

/// 逐条文本页：先列出每条消息（一行预览），点进去再选。
///
/// 内联的长按选择拿不到跨段选区，而整篇会话又太长、找不到要复制的那一段，
/// 所以按「消息」切开：定位靠列表，选中靠原生文本视图。
struct DshCopyTextSheet: View {
    struct Piece: Identifiable {
        enum Kind { case user, assistant, tool, notice }
        let id: String
        let kind: Kind
        let title: String
        let text: String
    }

    let pieces: [Piece]
    /// 滑到底时拉一页更早的消息；由会话页传入，与会话页共用同一批翻页 API。
    var loadOlder: (() async -> Void)?
    var hasMore: Bool = false
    var isLoading: Bool = false

    /// 筛选：全部 / 只看人话 / 只看工具。
    enum FilterMode: String, CaseIterable, Identifiable {
        case all = "全部"
        case talk = "只看人话"
        case tools = "只看工具"

        var id: String { rawValue }
    }

    @AppStorage("copyText.filter") private var filterMode: String = "all"
    @Environment(\.dismiss) private var dismiss

    private var shown: [Piece] {
        switch FilterMode(rawValue: filterMode) ?? .all {
        case .all:
            return pieces
        case .talk:
            return pieces.filter { $0.kind == .user || $0.kind == .assistant }
        case .tools:
            return pieces.filter { $0.kind == .tool }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { piece in
                    NavigationLink {
                        FullTextPage(title: piece.title, text: piece.text)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(piece.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(piece.text)
                                .font(.system(size: 15))
                                .lineLimit(2)
                        }
                    }
                }
                // 列表尾部的翻页触发点：出现一次拉一页，没有更多就不再出现。
                if hasMore, let loadOlder {
                    Section {
                        if isLoading {
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
                            LoadOlderTrigger { await loadOlder() }
                        }
                    }
                }
            }
            .navigationTitle("选择文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("筛选", selection: $filterMode) {
                        ForEach(FilterMode.allCases) { option in
                            Text(option.rawValue).tag(option.rawValue)
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
}

/// 列表尾部的触发器：只在一「出现」时拉一页，重复重建不再触发。
private struct LoadOlderTrigger: View {
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

private struct FullTextPage: View {
    let title: String
    let text: String

    var body: some View {
        FullTextSelectable(text: text)
            .background(Palette.paper)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制全部") { DshClipboard.copy(text) }
                        .disabled(text.isEmpty)
                }
            }
    }
}

private struct FullTextSelectable: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.font = .systemFont(ofSize: 15)
        view.dataDetectorTypes = []
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

extension Conversation {
    /// 每条消息一段纯文本：给「选择文本」页做定位用。
    var pieces: [DshCopyTextSheet.Piece] {
        items.compactMap { item -> DshCopyTextSheet.Piece? in
            switch item {
            case .user(let turn):
                guard !turn.synthetic, !turn.text.isEmpty else { return nil }
                return .init(id: item.id, kind: .user, title: "我", text: turn.text)
            case .assistant(let turn):
                guard !turn.text.isEmpty else { return nil }
                return .init(id: item.id, kind: .assistant, title: "助手", text: turn.text)
            case .tool(let card):
                return .init(id: item.id, kind: .tool, title: "工具 · " + card.name, text: card.arguments)
            case .notice(let notice):
                return .init(id: item.id, kind: .notice, title: "提示", text: notice.text)
            }
        }
    }
}
#endif

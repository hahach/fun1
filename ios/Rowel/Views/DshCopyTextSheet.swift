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

    /// 只留人与助手的回复，把工具轮与提示折叠掉。
    @AppStorage("copyText.hideTools") private var hideTools = false
    @Environment(\.dismiss) private var dismiss

    private var shown: [Piece] {
        hideTools ? pieces.filter { $0.kind == .user || $0.kind == .assistant } : pieces
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("过滤工具轮", isOn: $hideTools)
                        .font(.callout)
                }
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
            }
            .navigationTitle("选择文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
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
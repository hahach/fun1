import SwiftUI
#if canImport(UIKit)
import UIKit

/// 选区自检：同一个 App 里四种写法，看到底哪一层拿不到选择把手。
///
/// 只用于排障，不参与业务。四段文字内容相同，长按后分别看有没有蓝色/红色把手与高亮。
struct DshSelectionProbeView: View {
    @State private var anchor: String? = "probe.f"
    private let sample = "选择自检：这一段用于比较四种写法的长按选择行为。长按本段文字，观察是否出现选择把手与选区高亮。"

    var body: some View {
        List {
            Section("A．纯 SwiftUI Text（sheet 内、无滚动容器）") {
                Text(sample)
                    .textSelection(.enabled)
            }

            Section("B．SwiftUI Text（ScrollView + LazyVStack，模仿会话页）") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text(sample)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }

            Section("C．UITextView（本仓 SelectableText，只允许复制）") {
                SelectableText(attributed: AttributedString(sample), fontSize: 15)
            }

            Section("D．UITextView（最朴素：可选、可编辑关闭，无任何覆盖）") {
                RawTextView(text: sample)
                    .frame(height: 90)
            }

            Section("E．UITextView（ScrollView + LazyVStack，模仿会话页）") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        RawTextView(text: sample).frame(height: 90)
                    }
                }
                .frame(height: 120)
            }

            Section("F．UITextView（再加 scrollTargetLayout + scrollPosition，与会话页完全一致）") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        RawTextView(text: sample)
                            .frame(height: 90)
                            .id("probe.f")
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $anchor, anchor: .top)
                .frame(height: 120)
            }

            Section("G．完全复刻会话页：MarkdownText + 卡片 + scrollTargetLayout/scrollPosition") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        MarkdownText(source: sample)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Metrics.gap)
                            .background(DshTheme.assistantCard,
                                        in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                                .stroke(Palette.line, lineWidth: 0.5)
                                .allowsHitTesting(false))
                            .id("probe.g")
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $anchor, anchor: .top)
                .frame(height: 140)
            }

            Section("H．两段纯文字（空行分隔，验跨段）") {
                MarkdownText(source: "第一段：长按从这里开始往下拖。\n\n第二段：如果选区能覆盖到这里，说明跨段可用。")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Text("把每一段长按的结果告诉我：有没有把手、选区是什么颜色、菜单里有哪些项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("选区自检")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RawTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 15)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#endif
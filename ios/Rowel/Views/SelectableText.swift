import SwiftUI
#if canImport(UIKit)
import UIKit

/// 原生可选文本。
///
/// SwiftUI 的 `Text + textSelection` 在 LiveContainer 重签名环境里只弹出菜单、不给选择把手；
/// 换 `UITextView` 拿真正的选区与把手，菜单只留「复制」。加粗/斜体/行内代码由
/// AttributedString 的 inlinePresentationIntent 逐段映射到字体，链接仍可点。
struct SelectableText: UIViewRepresentable {
    let attributed: AttributedString
    let fontSize: CGFloat
    /// 链接点击先交给宿主的处理函数：UITextView 会自己把链接丢给 UIApplication，
    /// 绕开会话页挂的 openURL 拦截器，file:// 与相对路径就点不出预览（B-131）。
    @Environment(\.dshLinkTap) private var linkTap
    var weight: UIFont.Weight = .regular
    var color: UIColor = .label

    func makeUIView(context: Context) -> SelectableTextView {
        let view = SelectableTextView()
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: SelectableTextView, context: Context) {
        // 只有内容真的变了才重设：每次更新都换 attributedText 会把正在拖的选区打断，
        // 表现为「先跳到句末、再跳到行末、最后才到手指位置」。
        context.coordinator.linkTap = linkTap
        let next = rendered()
        if context.coordinator.lastText?.isEqual(to: next) != true {
            context.coordinator.lastText = next
            view.attributedText = next
            view.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastText: NSAttributedString?
        var linkTap: ((URL) -> Bool)?

        /// 文本里的链接点下去先问宿主：它会认本机路径（会话页据此开文件预览）；
        /// 认不出来就返回 false，交还系统默认动作。
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return linkTap?(url) == true ? nil : defaultAction
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    private func rendered() -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent
            var font = UIFont.systemFont(ofSize: fontSize, weight: weight)
            if intent?.contains(.code) == true {
                font = UIFont.monospacedSystemFont(ofSize: fontSize - 1.5, weight: .regular)
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent?.contains(.stronglyEmphasized) == true { traits.insert(.traitBold) }
                if intent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
                if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    font = UIFont(descriptor: descriptor, size: fontSize)
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = UIColor.tintColor
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: output.length))
        return output
    }
}

/// 只允许「复制」，不给其他编辑动作。
final class SelectableTextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(copy(_:))
    }
}
#endif

/// 文本内链接的点击处理：返回 true 表示已处理（不再交给系统）。
struct LinkTapHandlerKey: EnvironmentKey {
    static let defaultValue: (URL) -> Bool = { _ in false }
}

extension EnvironmentValues {
    var dshLinkTap: (URL) -> Bool {
        get { self[LinkTapHandlerKey.self] }
        set { self[LinkTapHandlerKey.self] = newValue }
    }
}

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
        let coordinator = context.coordinator
        // 链接处理器可以每拍都是新闭包（会话页每次 body 求值都造一个）：换掉它是常数开销，
        // 真正贵的是下面那份 NSAttributedString——逐 run 造字体、造属性字典。
        coordinator.linkTap = linkTap
        let inputs = Inputs(attributed: attributed, fontSize: fontSize, weight: weight.rawValue, color: color)
        // 第一道闸：输入没变就直接收手——不碰 textStorage、不重建属性串、不请 SwiftUI 重量高度。
        // 流式期间父视图每帧都在求值，这条早退把「每帧、每段」变成「每段真正变了才做」。
        guard coordinator.lastInputs != inputs else { return }
        coordinator.lastInputs = inputs
        // 第二道闸：输入变了但画出来一样（比如只多了不参与渲染的属性）就不重设——
        // 每次更新都换 attributedText 会把正在拖的选区打断，表现为「先跳到句末、再跳到行末」。
        let next = rendered()
        guard coordinator.lastText?.isEqual(to: next) != true else { return }
        coordinator.lastText = next
        view.attributedText = next
        view.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 画出来的东西的全部输入：文本及其行内样式、字号、字重、颜色。
    ///
    /// 宽度不在里面：属性串与换行无关（段落样式固定按词换行），行数由 `sizeThatFits`
    /// 按当前提议宽度现算；把宽度记进指纹，转屏/键盘顶上来时反而会白白重建一遍。
    /// 不用 private：`Coordinator.lastInputs` 是模块内可见的，属性的类型不能比它更封闭。
    struct Inputs: Equatable {
        var attributed: AttributedString
        var fontSize: CGFloat
        /// `UIFont.Weight` 不保证可比，比它的原始值。
        var weight: CGFloat
        var color: UIColor
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastText: NSAttributedString?
        /// 上一次真正渲染时的输入指纹（见 `Inputs`）：相同就跳过整条重设路径。
        var lastInputs: Inputs?
        var linkTap: ((URL) -> Bool)?

        /// 文本里的链接点下去先问宿主：它会认本机路径（会话页据此开文件预览）；
        /// 认不出来就返回 false，交还系统默认动作。
        ///
        /// 认下来时回的是**空动作**，不是 nil：nil 在 UIKit 里不等于「这次点击作废」，
        /// 而是「没有主动作，那就改成弹菜单」——系统的链接菜单（打开／复制／分享）
        /// 正是从这个返回值漏出来的（B-165）。
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return linkTap?(url) == true ? UIAction { _ in } : defaultAction
        }

        /// 本地文件链接不给菜单：点下去只走上面那条主动作，不再多弹一层系统菜单（B-165）。
        ///
        /// 只掐带「本机路径」的那类链接（`file://` 与无 scheme 的相对/绝对路径，
        /// 判据与宿主 `localPath` 同一条边界）；http(s) 等外链照旧拿系统菜单——
        /// 它们的菜单里「复制链接／分享」有用，且它们的点击本来就走 defaultAction。
        /// 普通选区的编辑菜单不走这里，长按选中后的「复制」由
        /// SelectableTextView.canPerformAction 收敛，不受影响。
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard case .link(let url) = textItem.content else {
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            }
            if let scheme = url.scheme?.lowercased(), scheme != "file" {
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            }
            return nil
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

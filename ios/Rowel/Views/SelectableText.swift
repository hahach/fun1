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
    /// 会话的工作目录：长按链接「复制绝对路径」靠它补全相对路径。
    @Environment(\.sessionWorkingDirectory) private var workingDirectory
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
        coordinator.workingDirectory = workingDirectory
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
        /// 工作目录不参与渲染，只喂菜单里的路径补全，所以不进 `Inputs` 指纹。
        var workingDirectory: String?

        /// 点链接的主动作：本机路径链接换成我们自己的动作，外链交还 `defaultAction`。
        ///
        /// 打开预览的副作用写在 `UIAction` 的处理器里，取动作这一下只做判定。
        /// 系统来取主动作的时机不限于点击——长按开始也会先问一次；副作用若留在取动作
        /// 的当下，长按就照样开预览（菜单同时照常弹出）。
        ///
        /// 回的是**非空动作**，不是 nil：nil 在 UIKit 里不等于「这次点击作废」，
        /// 而是「没有主动作，那就改成弹菜单」——系统的链接菜单（打开／复制／分享）
        /// 正是从这个返回值漏出来的（B-165）。
        ///
        /// 本机路径按 `LinkTargetPath` 判定，与长按菜单同一条边界；不拿 `linkTap`
        /// 试判——它带打开预览的副作用，试一次就开一次。宿主最终没认下时这次点击落空，
        /// 与系统打开无 scheme 的相对串同样打不开。
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            Diagnostics.shared.log(.info, "链接", "交互=点击 形态=\(Self.shape(of: url))")
            guard Self.resolves(url, cwd: workingDirectory) else { return defaultAction }
            return UIAction { [weak self] _ in _ = self?.linkTap?(url) }
        }

        /// 本机路径链接的长按菜单：复制绝对路径、选择。
        ///
        /// 只认带「本机路径」的那类链接（`file://` 与无 scheme 的相对/绝对路径，
        /// 判据与宿主 `localPath` 同一条边界）；http(s) 等外链照旧拿系统菜单——
        /// 它们的菜单里「复制链接／分享」有用，且它们的点击本来就走 defaultAction。
        /// 本机路径链接不给系统的打开／复制／分享（B-165），也不因菜单非空而回潮。
        ///
        /// 本机路径**一律回菜单**：认不出绝对路径时（相对路径缺工作目录、路径为空）
        /// 只放「选择」。回 nil 等于没菜单可弹，长按落到主动作上，就是「长按也开预览」。
        /// 点击打开走 `primaryActionFor`，不经过这里。
        /// 普通选区的编辑菜单不走这里，长按选中后的「复制」由
        /// SelectableTextView.canPerformAction 收敛，不受影响。
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard case .link(let url) = textItem.content else {
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            }
            if let scheme = url.scheme?.lowercased(), scheme != "file" {
                Diagnostics.shared.log(.info, "链接", "交互=长按 形态=外链")
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            }
            let shape = Self.shape(of: url)
            let target = LinkTargetPath.absolute(from: url, cwd: workingDirectory)
            let resolved: String? = (target?.isEmpty == false) ? target : nil
            if resolved == nil {
                let reason = shape == "相对" && (workingDirectory ?? "").isEmpty ? "缺工作目录" : "路径为空"
                Diagnostics.shared.log(.info, "链接", "交互=长按 形态=\(shape) 无绝对路径：\(reason)")
            } else {
                Diagnostics.shared.log(.info, "链接", "交互=长按 形态=\(shape)")
            }
            // 链接区自己长按只会弹菜单、起不了选区：这一项把选区摆到链接文字上，
            // 拖把手与菜单里的「复制」照常由系统接管。
            let select = UIAction(title: "选择", image: UIImage(systemName: "text.cursor")) { [weak textView] _ in
                guard let textView, let range = Coordinator.range(of: url, in: textView) else { return }
                textView.becomeFirstResponder()
                textView.selectedRange = range
            }
            guard let absolute = resolved else {
                return UITextItem.MenuConfiguration(menu: UIMenu(children: [select]))
            }
            let copyPath = UIAction(title: "复制绝对路径", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = absolute
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            return UITextItem.MenuConfiguration(menu: UIMenu(children: [copyPath, select]))
        }

        /// 链接形态，只给日志用：`file`／`相对`／`绝对`／`外链`。
        ///
        /// 无 scheme 时按原串首字符分相对与绝对（`/` 与 `~` 算绝对），
        /// 百分号编码的路径先解回来再判。
        private static func shape(of url: URL) -> String {
            if url.isFileURL { return "file" }
            if url.scheme != nil { return "外链" }
            let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            return raw.hasPrefix("/") || raw.hasPrefix("~") ? "绝对" : "相对"
        }

        /// 本机路径能否换算成绝对路径：判据与长按菜单同一条边界（`LinkTargetPath`）。
        private static func resolves(_ url: URL, cwd: String?) -> Bool {
            guard let path = LinkTargetPath.absolute(from: url, cwd: cwd) else { return false }
            return !path.isEmpty
        }

        /// 该链接在文本里的范围：按 `.link` 属性逐段比对 URL，取第一处。
        ///
        /// 属性值由 `rendered()` 写成 URL；顺带认字符串形式，属性串经别处改写也不会失配。
        private static func range(of url: URL, in textView: UITextView) -> NSRange? {
            let storage = textView.textStorage
            var found: NSRange?
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                let linked: URL?
                if let value = value as? URL {
                    linked = value
                } else if let value = value as? String {
                    linked = URL(string: value)
                } else {
                    linked = nil
                }
                guard linked == url else { return }
                found = range
                stop.pointee = true
            }
            return found
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

/// 会话的工作目录：正文里的相对路径链接按它补成全路径（长按菜单「复制绝对路径」）。
struct SessionWorkingDirectoryKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var sessionWorkingDirectory: String? {
        get { self[SessionWorkingDirectoryKey.self] }
        set { self[SessionWorkingDirectoryKey.self] = newValue }
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 本仓对上游视觉的增量。
///
/// 上游 DesignSystem.swift 是一套很窄的调色板（纸面/表面/凹陷面/发丝线），刻意不收录
/// 卡片底色与按钮底色——上游没有卡片式正文，也没有胶囊按钮。这里补齐这两档，
/// 不改上游文件，避免把本仓的审美混进需要与上游同步的清单里。
enum DshTheme {
    /// agent 正文档的底色：比纸面略冷一档，让「回答」与「页面」分开。
    static let assistantCard = Color(light: .init(red: 0.957, green: 0.965, blue: 0.980),
                                     dark: .init(white: 0.145))
    /// 胶囊 chip 的底：输入框上方那排工具用。
    static let chip = Color(light: .init(white: 0.935), dark: .init(white: 0.205))
    /// 破坏性动作（停止）的底。
    static let dangerChip = Color(light: .init(red: 0.985, green: 0.93, blue: 0.93),
                                  dark: .init(red: 0.27, green: 0.14, blue: 0.14))
}

/// 输入框上方工具条的胶囊：一行文字（权限、模型、思考强度）。
struct DshChip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DshTheme.chip, in: Capsule())
            .overlay(Capsule().stroke(Palette.line, lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

/// 复制到剪贴板。只包一层，免得每个视图各写一遍 UIKit 条件编译。
enum DshClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

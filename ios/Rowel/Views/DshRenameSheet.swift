import SwiftUI

/// 重命名会话：一个输入框加保存。
///
/// 用 sheet 而不是 alert：alert 里的 TextField 在列表行的 contextMenu 之后偶尔不肯出来，
/// 这类「点了没反应」最难查，索性换成确定的呈现方式。
struct DshRenameSheet: View {
    let session: SessionSummary
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(session: SessionSummary, onSave: @escaping (String) -> Void) {
        self.session = session
        self.onSave = onSave
        _text = State(initialValue: session.displayTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("重命名会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// 一段文本的编辑弹窗：待发消息改名之类的轻量场景共用。
struct DshTextEditSheet: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(title: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("内容", text: $text, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

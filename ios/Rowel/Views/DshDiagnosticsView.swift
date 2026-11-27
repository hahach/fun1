import SwiftUI

/// 诊断与日志：把最近发生的事整份交出去。
///
/// 对真机排障而言，唯一要紧的是「能把原文交出去」——所以这里第一等公民是
/// 复制与分享，而不是排版漂亮的图表。
struct DshDiagnosticsView: View {
    @ObservedObject private var diagnostics = Diagnostics.shared
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Button {
                    diagnostics.copyToPasteboard()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制到剪贴板" : "复制全部日志", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: diagnostics.transcript) {
                    Label("分享为文本", systemImage: "square.and.arrow.up")
                }
                Button("清空日志", role: .destructive) { diagnostics.clear() }
            }

            Section("最近 \(diagnostics.entries.count) 条") {
                if diagnostics.entries.isEmpty {
                    Text("还没有记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(diagnostics.entries) { entry in
                    Text(entry.line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(entry.level == .fail ? Color.red : (entry.level == .warn ? Color.orange : Color.primary))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("诊断与日志")
        .navigationBarTitleDisplayMode(.inline)
    }
}


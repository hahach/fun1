import SwiftUI
import Foundation
import UIKit
import DshClientCore

/// 文件预览：走隧道里的 `GET /api/file?path=<绝对路径>`。
///
/// 对话里点 md 里的文件链接时用它——不必为了看一眼文件去开 web UI。
struct DshFilePreviewView: View {
    let transport: DshTransport
    let path: String

    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var image: UIImage?
    @State private var errorText: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ScrollView {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                } else if let text {
                    ScrollView {
                        if isMarkdown {
                            // md 文件与回复正文同一个渲染器；其余文本保持等宽原文（B-123）。
                            MarkdownText(source: text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        } else {
                            Text(text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                } else if let errorText {
                    Text(errorText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding()
                } else if loading {
                    ProgressView("读取文件…")
                }
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text ?? path
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(text == nil)
                }
            }
            .task { await load() }
        }
    }

    /// md 家族扩展名：交给 `MarkdownText`，而不是等宽原文。
    private var isMarkdown: Bool {
        ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var components = URLComponents(url: transport.dshSession.baseURL.appendingPathComponent("api/file"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        let credentials = transport.dshSession.credentials
        request.setValue("\(credentials.cookieName)=\(credentials.cookieValue)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                errorText = "HTTP \(status)"
                return
            }
            if let decoded = UIImage(data: data) {
                image = decoded
            } else {
                text = String(decoding: data, as: UTF8.self)
            }
            Diagnostics.shared.log(.info, "文件", "读取成功 \(path)（\(data.count) 字节）")
        } catch {
            errorText = DshBoard.message(error)
            Diagnostics.shared.log(.fail, "文件", DshBoard.message(error))
        }
    }
}


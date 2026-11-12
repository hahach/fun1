import SwiftUI
import UIKit
import DshClientCore
import SwiftTerm

/// 终端页：复用 dsh 会话那条 SSH 连接开一个 PTY。
///
/// 渲染与按键交给 SwiftTerm——它自带跟随键盘的按键条（Esc/Tab/Ctrl/方向键），
/// 这里不再叠一条自己的，只补字号与「重开」这类它没有的入口。
struct DshTerminalScreen: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("terminal.fontSize") private var fontSize: Double = 12

    var body: some View {
        Group {
            if let errorText = session.errorText {
                VStack(spacing: 12) {
                    Text(errorText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button("重开终端") { Task { await session.reopen() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if session.isOpen {
                TerminalHost(session: session, fontSize: CGFloat(fontSize))
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView("打开终端…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 终端是深色：整页黑底，重开时不会闪一下白屏。
        .background(Color.black)
        .foregroundStyle(.white)
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("字号 大一点") { fontSize = min(28, fontSize + 1) }
                    Button("字号 小一点") { fontSize = max(8, fontSize - 1) }
                    Divider()
                    Button("重开终端") { Task { await session.reopen() } }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .task { await session.openIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            // 回前台时 SSH 连接多半已死：有错误就再来一次（内部会整栈重建）。
            if phase == .active, session.errorText != nil {
                Task { await session.openIfNeeded() }
            }
        }
    }
}

private struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        if uiView.font.pointSize != fontSize {
            uiView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: TerminalSession
        private weak var view: TerminalView?

        init(session: TerminalSession) {
            self.session = session
        }

        func attach(_ view: TerminalView) {
            self.view = view
            session.attach { [weak view] data in
                view?.feed(byteArray: data)
            }
        }

        func detach() {
            session.detach()
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string.map { Data($0.utf8) }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }

        func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }

        func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }

        func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }

        func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
    }
}


import SwiftUI

/// 一条会话的直接子代理：单独一页，点进去看它自己的对话。
///
/// 子代理是真实会话，但按 sessionId 直接读会被 `session/agent-busy` 拒；必须带父会话寻址，
/// 所以这里把父会话的 `SubagentParent` 一起传下去。
struct DshSubagentListView: View {
    let transport: DshTransport
    @ObservedObject var board: DshBoard
    let parent: SessionSummary

    private var children: [SessionSummary] { board.children(of: parent.id) }

    var body: some View {
        List(children) { child in
            NavigationLink {
                DshConversationView(
                    transport: transport,
                    summary: child,
                    board: board,
                    parent: SubagentParent(id: parent.id, mode: "unknown")
                )
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(child.displayTitle)
                        .font(.body)
                    HStack(spacing: 8) {
                        if child.running {
                            Text("运行中").font(.caption2).foregroundStyle(.green)
                        }
                        Text(child.updatedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("子代理")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if children.isEmpty {
                ContentUnavailableView("没有子代理", systemImage: "person.2")
            }
        }
    }
}


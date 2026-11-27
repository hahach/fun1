import SwiftUI

/// 归档会话：机器只把它们从分组面上藏起来，日志还在，所以单独一页列出来看，
/// 并且能放回去（`workspace/unarchiveSession`）。
struct DshArchiveListView: View {
    @ObservedObject var board: DshBoard

    var body: some View {
        List(board.archivedSessions) { session in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle)
                    Text(session.updatedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复") {
                    Task { await board.unarchive(session.id) }
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle("归档")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if board.archivedSessions.isEmpty {
                ContentUnavailableView("没有归档会话", systemImage: "archivebox")
            }
        }
    }
}


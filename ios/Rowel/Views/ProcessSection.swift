import SwiftUI

/// 一轮里「思考＋工具」的连续段。
///
/// 桌面把过程完全展开的读法照搬到手机上，回复正文会被挤到看不见的地方。
/// 这里把过程收成一条可展开的段：默认折叠、标题一行带步数；展开后标题在滑到
/// 顶端时冻结，滚到段尾自然释放，随时能收回。正文与系统提示不进段内。
enum ProcessPart: Identifiable, Equatable {
    case thought(id: String, text: String, at: Date)
    case tool(ToolCard)

    var id: String {
        switch self {
        case .thought(let id, _, _): return id
        case .tool(let card): return card.id
        }
    }

    var at: Date {
        switch self {
        case .thought(_, _, let at): return at
        case .tool(let card): return card.at
        }
    }
}

struct ProcessGroup: Identifiable, Equatable {
    var id: String
    var parts: [ProcessPart]

    var toolCount: Int {
        parts.reduce(0) { count, part in
            if case .tool = part { return count + 1 }
            return count
        }
    }

    var hasFailure: Bool {
        parts.contains { part in
            if case .tool(let card) = part { return card.failed }
            return false
        }
    }

    var isRunning: Bool {
        parts.contains { part in
            if case .tool(let card) = part { return card.running }
            return false
        }
    }

    /// 段的起止：起自段内第一件东西的时间，止于最后一张工具卡的收尾时间。
    /// 还有工具在跑就没有终点，不给时长。
    var span: TimeInterval? {
        guard let first = parts.first?.at else { return nil }
        var last: Date?
        for part in parts {
            if case .tool(let card) = part {
                guard let finished = card.finishedAt else { return nil }
                last = max(last ?? finished, finished)
            }
        }
        guard let end = last, end > first else { return nil }
        return end.timeIntervalSince(first)
    }
}

/// 转录物的一行：普通条目，或者一段收起来的过程。
enum TranscriptRow: Identifiable {
    case item(ConversationItem, settled: Bool)
    case process(ProcessGroup)

    var id: String {
        switch self {
        case .item(let item, _): return item.id
        case .process(let group): return group.id
        }
    }
}

enum TranscriptLayout {
    /// 把平铺的条目折成行：连续的「思考＋工具」并成一段，正文与系统提示留在外面。
    static func rows(_ items: [ConversationItem], turnEnds: Set<String>) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var group: ProcessGroup?

        func flush() {
            if let held = group, !held.parts.isEmpty { rows.append(.process(held)) }
            group = nil
        }

        for item in items {
            switch item {
            case .assistant(let turn):
                // 思考属于过程；正文一出现就把段断开——段里只放「没说出结论的那部分」。
                if !turn.reasoning.isEmpty {
                    if group == nil { group = ProcessGroup(id: "process-\(turn.id)", parts: []) }
                    group?.parts.append(.thought(id: turn.id, text: turn.reasoning, at: turn.at))
                }
                if !turn.text.isEmpty {
                    flush()
                    rows.append(.item(item, settled: turnEnds.contains(item.id)))
                }
            case .tool(let card):
                if group == nil { group = ProcessGroup(id: "process-\(card.id)", parts: []) }
                group?.parts.append(.tool(card))
            case .user, .notice:
                flush()
                rows.append(.item(item, settled: false))
            }
        }
        flush()
        return rows
    }
}

/// 段在滚动坐标里的位置。冻结与否由它决定：标题滑过顶端、段身还没走完时冻结。
struct ProcessFrame: Equatable {
    var id: String
    var minY: CGFloat
    var maxY: CGFloat
}

struct ProcessFrameKey: PreferenceKey {
    static var defaultValue: [String: ProcessFrame] = [:]

    static func reduce(value: inout [String: ProcessFrame], nextValue: () -> [String: ProcessFrame]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 段标题。折叠态就在正文流里跟着滚；展开后滑到顶端由外层叠一份同样的标题冻结。
struct ProcessHeader: View {
    let group: ProcessGroup
    let expanded: Bool
    var live: Bool = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if group.hasFailure {
                    Circle()
                        .fill(Palette.bad)
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.well, in: Capsule())
            .overlay(Capsule().stroke(Palette.line, lineWidth: 0.5))
            .contentShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        // 冻结时盖住身后滚过的内容：这条不透明是前提，不是装饰。
        .background(Palette.paper)
    }

    private var title: String {
        var text = group.toolCount > 0 ? "过程 · \(group.toolCount) 步" : "过程 · 思考"
        if live || group.isRunning { text += " · 进行中" }
        return text
    }

    private var trailing: String? {
        guard !live, !group.isRunning, let span = group.span else { return nil }
        if span >= 60 {
            return "\(Int(span) / 60) 分 \(Int(span) % 60) 秒"
        }
        return "\(Int(max(span, 1))) 秒"
    }
}

/// 一段过程：标题一行，展开后在下面铺思考与工具卡。
struct ProcessSection: View {
    let group: ProcessGroup
    let expanded: Bool
    var live: Bool = false
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            ProcessHeader(group: group, expanded: expanded, live: live, toggle: toggle)
            if expanded {
                VStack(alignment: .leading, spacing: Metrics.tight) {
                    ForEach(group.parts) { part in
                        switch part {
                        // 两个子视图都只有「画什么」这一份输入：内容没变就不重算。
                        // 展开块该有的刷新由外层 ProcessRow 放行，这里只省重复计算。
                        // live 段（本页正在跑，或段里还有工具在跑）的思考尾巴还在长，
                        // 交给 ThoughtPart 把已定稿的前缀单独拎出来，别每次都重排全文。
                        case .thought(_, let text, _): ThoughtPart(text: text, live: live || group.isRunning).equatable()
                        case .tool(let card): ToolCardView(card: card).equatable()
                        }
                    }
                }
            }
        }
        // 只有展开的段会冻结，也才需要量位置：折叠段连 GeometryReader 都不装。
        // 折叠后这段不再贡献 preference，合并字典里自然没有它，不必再补一次空字典。
        .background {
            if expanded {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .named(DshConversationView.transcriptSpace))
                    Color.clear.preference(
                        key: ProcessFrameKey.self,
                        value: [group.id: ProcessFrame(id: group.id, minY: frame.minY, maxY: frame.maxY)]
                    )
                }
            }
        }
    }
}

/// 行一级的闸门：折叠着、也没在跑的过程段，输入没变就不重算。
///
/// 展开块与 live 段一律判不等：它们的画面随内容与动画在变，闸门只该省重复计算，
/// 不该挡刷新。闭包不参与比较——它只认 group.id，段相同即同一个动作；
/// @State 的读写走同一份存储，跳过重算不会让闭包读到旧的展开态。
struct ProcessRow: View, Equatable {
    let group: ProcessGroup
    let expanded: Bool
    let live: Bool
    let toggle: () -> Void

    static func == (lhs: ProcessRow, rhs: ProcessRow) -> Bool {
        guard !lhs.expanded, !rhs.expanded, !lhs.live, !rhs.live else { return false }
        return lhs.group == rhs.group
    }

    var body: some View {
        ProcessSection(group: group, expanded: expanded, live: live, toggle: toggle)
    }
}

/// 段里的思考：展开段之后才出现，所以自己再折一层——整段思考往往比正文长得多。
struct ThoughtPart: View, Equatable {
    let text: String
    /// 这一段还在长（本页正在跑，或段里还有工具在跑）。
    let live: Bool
    @State private var expanded = false

    /// 正文与 live 参与比较：展开态是本视图自己的 @State，跳过重算时它照旧保存着。
    static func == (lhs: ThoughtPart, rhs: ThoughtPart) -> Bool { lhs.text == rhs.text && lhs.live == rhs.live }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                    // 计数用完整文本：切两截只是画法，字数还是整段。
                    Text(expanded ? "收起思考" : "思考 · \(text.count) 字")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                // 整条标题行可点：HStack 只占文字那么宽时，手指落在右侧空白上没反应，
                // 看起来就像「只有箭头能点」。铺满一行再把命中区补成矩形，正文在按钮外不受影响。
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                // 流式时最后一截还在变长：已定稿的前缀交给 EquatableSettledText，
                // 它只比文本，重排只落在尾段上。没有空行可分、或已收尾，就照旧画一个 Text。
                // 只有长思考才切：两截各是独立文本视图，跨视图拖选连不起来，短的不值当。
                if live, text.count > Self.splitThreshold, let cut = Self.cut(text) {
                    VStack(alignment: .leading, spacing: 0) {
                        EquatableSettledText(text: cut.settled).equatable()
                        thoughtBody(cut.tail)
                    }
                } else {
                    thoughtBody(text)
                }
            }
        }
        .padding(Metrics.gap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
    }

    /// 思考正文的样式：切两截时两边用同一套，视觉与可选中范围都不变。
    private func thoughtBody(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 切两截的字数门槛：低于它不值得为省重排换掉「整段可连续拖选」。
    private static let splitThreshold = 1500

    /// 按最后一个空行切。前缀连同这个空行一起留下（换行本身要留着，段落间距才不变）。
    private static func cut(_ text: String) -> (settled: String, tail: String)? {
        guard let range = text.range(of: "\n\n", options: .backwards) else { return nil }
        return (String(text[..<range.upperBound]), String(text[range.upperBound...]))
    }
}

/// 思考里已经定稿的那一截。
///
/// 只比文本：流式时它整段不变，SwiftUI 就跳过它的重排；在变的是后面那一截。
struct EquatableSettledText: View, Equatable {
    let text: String

    static func == (lhs: EquatableSettledText, rhs: EquatableSettledText) -> Bool { lhs.text == rhs.text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

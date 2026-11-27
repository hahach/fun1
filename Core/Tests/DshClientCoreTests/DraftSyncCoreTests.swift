import Foundation
import XCTest
@testable import DshClientCore

/// 共享场景清单驱动测试（契约 §13.4）。
///
/// 清单目录：Tests/DshClientCoreTests/Fixtures/draft-sync/*.json，与 Web 半读同一份文件；
/// 任一端与清单不符即判实现漂移。路径由 #filePath 推导，不含绝对路径。
///
/// 断言口径：逐事件喂给 DraftSyncCore，把全部动作按发生顺序拼成一条序列，与清单 expect 比对；
/// none 只作文档标记（"这次不写"），比对时两边都剔除——真正的判据是有意义动作的种类、参数与顺序。
final class DraftSyncCoreTests: XCTestCase {

    // MARK: - 清单定位与读取

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("draft-sync", isDirectory: true)
    }

    private static func fixtureURLs() throws -> [URL] {
        let directory = fixturesDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw FixtureError.missingDirectory(directory.path)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func decode(_ url: URL) throws -> Scenario {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Scenario.self, from: data)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missingDirectory(String)

        var description: String {
            switch self {
            case .missingDirectory(let path):
                return "共享场景清单目录不存在：" + path
            }
        }
    }

    // MARK: - 用例

    /// 清单本身的自检：条目够数、id 唯一且与文件名一致。
    func testFixtureInventory() throws {
        let urls = try Self.fixtureURLs()
        XCTAssertGreaterThanOrEqual(urls.count, 14, "共享场景清单至少 14 条，实际 \(urls.count)")
        var seen = Set<String>()
        for url in urls {
            let scenario = try Self.decode(url)
            XCTAssertFalse(scenario.id.isEmpty, "\(url.lastPathComponent)：id 为空")
            XCTAssertTrue(seen.insert(scenario.id).inserted, "场景 id 重复：\(scenario.id)")
            XCTAssertEqual(url.deletingPathExtension().lastPathComponent, scenario.id, "文件名应与场景 id 一致")
            XCTAssertFalse(scenario.events.isEmpty, "\(scenario.id)：事件序列为空")
        }
    }

    /// 逐事件断言动作序列（Web 半读同一份清单跑同一份判据）。
    func testScenariosMatchSharedChecklist() throws {
        for url in try Self.fixtureURLs() {
            let scenario = try Self.decode(url)
            var core = DraftSyncCore(
                mode: Self.mode(scenario.initial.mode),
                isBlank: scenario.initial.isBlank,
                cwd: scenario.initial.cwd
            )
            var produced: [DraftAction] = []
            var trace: [String] = []
            for (index, event) in scenario.events.enumerated() {
                let actions = Self.apply(event, to: &core, initial: scenario.initial)
                produced.append(contentsOf: actions)
                trace.append("[\(index)] \(event.type) -> \(actions)")
            }
            let expected = scenario.expect.map { $0.action }
            XCTAssertEqual(
                produced.filter { $0 != .none },
                expected.filter { $0 != .none },
                "\(scenario.id)（\(scenario.note ?? "")）动作序列不符，逐事件轨迹：\n" + trace.joined(separator: "\n")
            )
            if let expectation = scenario.expectState {
                Self.assertState(expectation, core.state, scenarioID: scenario.id)
            }
        }
    }

    // MARK: - 事件 → 调用

    private static func mode(_ raw: String) -> DraftMode {
        switch raw {
        case "localOnly": return .localOnly
        case "remote": return .remote
        default:
            XCTFail("未知 mode：\(raw)")
            return .remote
        }
    }

    private static func snapshot(_ event: RawEvent) -> DraftSnapshot {
        DraftSnapshot(text: event.textValue, updatedAt: event.updatedAt ?? 0)
    }

    private static func apply(_ event: RawEvent, to core: inout DraftSyncCore, initial: Initial) -> [DraftAction] {
        switch event.type {
        case "enterSession":
            return core.enterSession(localText: initial.localText ?? "", migrating: initial.migratingText)
        case "refresh":
            return core.refresh()
        case "remoteRead":
            return core.remoteRead(snapshot(event))
        case "readFailed":
            return core.readFailed()
        case "userEdited":
            return core.userEdited(event.textValue)
        case "debounceElapsed":
            return core.debounceElapsed()
        case "userCleared":
            return core.userCleared()
        case "writeSucceeded":
            return core.writeSucceeded(snapshot(event))
        case "writeTimedOut":
            return core.writeTimedOut()
        case "retryElapsed":
            return core.retryElapsed()
        case "capabilityMissing":
            return core.capabilityMissing()
        case "userAskedRemote":
            return core.userAskedRemote()
        case "userAskedOverwrite":
            return core.userAskedOverwrite()
        case "userChoseClearConsumed":
            return core.userChoseClearConsumed()
        case "userChoseKeepConsumed":
            return core.userChoseKeepConsumed()
        case "sessionBecameNonBlank":
            return core.sessionBecameNonBlank()
        case "writeFailed":
            switch event.error ?? "" {
            case "conflict":
                return core.writeFailed(.conflict(remote: event.remote ?? .empty))
            case "tooLarge":
                return core.writeFailed(.tooLarge(bytes: event.bytes ?? 0))
            case "unsupported":
                return core.writeFailed(.unsupported)
            default:
                XCTFail("未知 writeFailed.error：\(event.error ?? "nil")")
                return []
            }
        default:
            XCTFail("未知事件类型：\(event.type)")
            return []
        }
    }

    // MARK: - 状态断言

    private static func assertState(_ expectation: StateExpect, _ state: DraftViewState, scenarioID: String) {
        if let mode = expectation.mode {
            XCTAssertEqual(state.mode.rawValue, mode, "\(scenarioID) mode")
        }
        if let localText = expectation.localText {
            XCTAssertEqual(state.localText, localText, "\(scenarioID) localText")
        }
        if expectation.hasBase {
            XCTAssertEqual(state.base, expectation.base, "\(scenarioID) base")
        }
        if expectation.hasSyncedText {
            XCTAssertEqual(state.syncedText, expectation.syncedText, "\(scenarioID) syncedText")
        }
        if let suspended = expectation.suspended {
            XCTAssertEqual(state.isSuspended, suspended, "\(scenarioID) suspended")
        }
        if let conflict = expectation.conflict {
            XCTAssertEqual(state.conflict != nil, conflict, "\(scenarioID) conflict")
        }
        if let pending = expectation.pending {
            XCTAssertEqual(state.isPending, pending, "\(scenarioID) pending")
        }
        if let dirty = expectation.dirty {
            XCTAssertEqual(state.isDirty, dirty, "\(scenarioID) dirty")
        }
        if let isBlank = expectation.isBlank {
            XCTAssertEqual(state.isBlank, isBlank, "\(scenarioID) isBlank")
        }
        if let wroteWorkspaceRow = expectation.wroteWorkspaceRow {
            XCTAssertEqual(state.wroteWorkspaceRow, wroteWorkspaceRow, "\(scenarioID) wroteWorkspaceRow")
        }
    }

    // MARK: - 清单结构

    private struct Scenario: Decodable {
        let id: String
        let note: String?
        let initial: Initial
        let events: [RawEvent]
        let expect: [RawAction]
        let expectState: StateExpect?
    }

    private struct Initial: Decodable {
        let mode: String
        let isBlank: Bool
        let cwd: String?
        let localText: String?
        let migratingText: String?
    }

    private struct RawEvent: Decodable {
        let type: String
        let text: TextValue?
        let updatedAt: Int?
        let bytes: Int?
        let error: String?
        let remote: DraftSnapshot?

        var textValue: String { text?.text ?? "" }
    }

    private struct RawAction: Decodable {
        let type: String
        let text: TextValue?
        let base: Int?
        let cwd: String?
        let after: Double?
        let bytes: Int?
        let remote: DraftSnapshot?

        var action: DraftAction {
            switch type {
            case "get":
                return .get(cwd: cwd)
            case "set":
                return .set(text: text?.text ?? "", base: base, cwd: cwd)
            case "scheduleRetry":
                return .scheduleRetry(after: after ?? 0)
            case "backfill":
                return .backfill(text?.text ?? "")
            case "showConflict":
                return .showConflict(remote: remote ?? .empty)
            case "clearConflict":
                return .clearConflict
            case "showConsumed":
                return .showConsumed(remote: remote ?? .empty)
            case "clearConsumed":
                return .clearConsumed
            case "tooLarge":
                return .tooLarge(bytes: bytes ?? 0)
            case "degrade":
                return .degrade
            case "none":
                return .none
            default:
                XCTFail("未知期望动作类型：\(type)")
                return .none
            }
        }
    }

    /// 长文本用 { "repeat": "a", "count": 61440 } 写在清单里，两端各自展开，避免仓库里躺 60 KiB 字面量。
    private enum TextValue: Decodable, Equatable {
        case literal(String)
        case repeated(String, Int)

        var text: String {
            switch self {
            case .literal(let value):
                return value
            case .repeated(let unit, let count):
                return String(repeating: unit, count: count)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let literal = try? container.decode(String.self) {
                self = .literal(literal)
                return
            }
            let spec = try container.decode(RepeatSpec.self)
            self = .repeated(spec.unit, spec.count)
        }

        private struct RepeatSpec: Decodable {
            let unit: String
            let count: Int

            private enum CodingKeys: String, CodingKey {
                case unit = "repeat"
                case count
            }
        }
    }

    private struct StateExpect: Decodable {
        let mode: String?
        let localText: String?
        let hasBase: Bool
        let base: Int?
        let hasSyncedText: Bool
        let syncedText: String?
        let suspended: Bool?
        let conflict: Bool?
        let pending: Bool?
        let dirty: Bool?
        let isBlank: Bool?
        let wroteWorkspaceRow: Bool?

        private enum CodingKeys: String, CodingKey {
            case mode
            case localText
            case base
            case syncedText
            case suspended
            case conflict
            case pending
            case dirty
            case isBlank
            case wroteWorkspaceRow
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = try container.decodeIfPresent(String.self, forKey: .mode)
            localText = try container.decodeIfPresent(String.self, forKey: .localText)
            suspended = try container.decodeIfPresent(Bool.self, forKey: .suspended)
            conflict = try container.decodeIfPresent(Bool.self, forKey: .conflict)
            pending = try container.decodeIfPresent(Bool.self, forKey: .pending)
            dirty = try container.decodeIfPresent(Bool.self, forKey: .dirty)
            isBlank = try container.decodeIfPresent(Bool.self, forKey: .isBlank)
            wroteWorkspaceRow = try container.decodeIfPresent(Bool.self, forKey: .wroteWorkspaceRow)
            if container.contains(.base) {
                hasBase = true
                base = try container.decodeIfPresent(Int.self, forKey: .base)
            } else {
                hasBase = false
                base = nil
            }
            if container.contains(.syncedText) {
                hasSyncedText = true
                syncedText = try container.decodeIfPresent(String.self, forKey: .syncedText)
            } else {
                hasSyncedText = false
                syncedText = nil
            }
        }
    }
}

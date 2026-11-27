import Foundation
import XCTest
@testable import DshClientCore

/// 只在描述里带文本的错误：用来模拟 NIO/Citadel 的「通道已关」一类包装错误。
private struct PlainError: Error, CustomStringConvertible {
    let text: String
    var description: String { text }
}

/// 降级态与降级错误映射：全是纯函数，离线跑，不碰网络。
final class DshDegradationTests: XCTestCase {
    // MARK: 阶段归类

    func testStageLabelsNameEveryStep() {
        XCTAssertEqual(DshFailureRules.stageLabel(.resolve), "解析 dsh 目标")
        XCTAssertEqual(DshFailureRules.stageLabel(.forward), "起本地转发")
        XCTAssertEqual(DshFailureRules.stageLabel(.probe), "隧道自检")
        XCTAssertEqual(DshFailureRules.stageLabel(.authenticate), "取 dsh 凭据")
        XCTAssertEqual(Degraded(stage: .probe, reason: "x").stageLabel, "隧道自检")
    }

    func testDegradedMessageReadsAsCallerNeeds() {
        let degraded = Degraded(stage: .authenticate, reason: "候选 token 全被拒（HTTP 401）")
        XCTAssertEqual(degraded.message, "SSH 已连、dsh 未就绪：候选 token 全被拒（HTTP 401）")
    }

    // MARK: 原因串

    func testReasonPrefersLocalizedDescription() {
        XCTAssertEqual(
            DshFailureRules.reason(for: BootstrapError.noLaunchURL),
            "主机上找不到带 token 的启动 URL（dsh-web 没在跑？）"
        )
        XCTAssertEqual(
            DshFailureRules.reason(for: BootstrapError.tunnelUnreachable(reason: "端口通但无响应（3000 ms）")),
            "隧道不通：端口通但无响应（3000 ms）"
        )
    }

    func testReasonFallsBackToDescription() {
        XCTAssertEqual(DshFailureRules.reason(for: PlainError(text: "boom")), "boom")
    }

    // MARK: 阶段 + 错误 → 降级态

    func testDegradedKeepsStageItWasGiven() {
        let value = DshFailureRules.degraded(stage: .forward, error: LocalForwarder.ForwardError.noLocalPort)
        XCTAssertEqual(value.stage, .forward)
        XCTAssertFalse(value.reason.isEmpty)
        XCTAssertFalse(value.isTunnelProblem)
    }

    /// 首连「隧道不通就整栈重建一次」只认隧道类失败：token 不对重建也没用。
    func testTunnelProblemFlagOnlyForTunnelFailures() {
        let probe = DshFailureRules.degraded(
            stage: .probe,
            error: BootstrapError.tunnelUnreachable(reason: "端口通但无响应（3000 ms）")
        )
        XCTAssertTrue(probe.isTunnelProblem)

        let network = DshFailureRules.degraded(
            stage: .authenticate,
            error: BootstrapError.tunnelUnreachable(reason: "连续 3 次请求无响应")
        )
        XCTAssertTrue(network.isTunnelProblem)

        let token = DshFailureRules.degraded(stage: .authenticate, error: BootstrapError.notAuthorized(status: 401))
        XCTAssertFalse(token.isTunnelProblem)

        let resolve = DshFailureRules.degraded(stage: .resolve, error: BootstrapError.noLaunchURL)
        XCTAssertFalse(resolve.isTunnelProblem)
    }

    // MARK: SSH 死活的判定

    func testSSHUnavailableRecognizesClosedChannel() {
        let reason = DshFailureRules.sshUnavailableReason(
            PlainError(text: "Citadel.SSHClientError.channelCreationFailed(\"creatingChannelAfterClosure\")")
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("creatingChannelAfterClosure") == true)
    }

    func testSSHUnavailableRecognizesChannelClosedVariants() {
        for text in [
            "NIOCore.ChannelError.ioOnClosedChannel",
            "ChannelError(errorCode: already closed)",
            "SSH connection closed by remote host",
        ] {
            XCTAssertNotNil(DshFailureRules.sshUnavailableReason(PlainError(text: text)), text)
        }
    }

    func testSSHUnavailableIgnoresDshSideFailures() {
        XCTAssertNil(DshFailureRules.sshUnavailableReason(BootstrapError.noLaunchURL))
        XCTAssertNil(DshFailureRules.sshUnavailableReason(BootstrapError.tunnelUnreachable(reason: "端口通但无响应")))
        XCTAssertNil(DshFailureRules.sshUnavailableReason(PlainError(text: "boom")))
    }

    func testSSHUnavailableMapsConnectionErrors() {
        XCTAssertEqual(
            DshFailureRules.sshUnavailableReason(SSHClientConnection.ConnectionError.notConnected),
            "SSH 尚未连接"
        )
        // 连接阶段的失败不属于「连上之后死了」。
        XCTAssertNil(DshFailureRules.sshUnavailableReason(
            SSHClientConnection.ConnectionError.refused(host: "h", port: 22)
        ))
    }

    func testSSHUnavailableIsIdempotentOverSessionErrors() {
        XCTAssertEqual(DshFailureRules.sshUnavailableReason(DshSessionError.sshUnavailable(reason: "通道已关闭")), "通道已关闭")
        XCTAssertEqual(DshFailureRules.sshUnavailableReason(DshSessionError.notConnected), "SSH 尚未连接")
        XCTAssertNil(DshFailureRules.sshUnavailableReason(
            DshSessionError.dshNotReady(Degraded(stage: .probe, reason: "x"))
        ))
    }

    // MARK: 可区分的错误

    func testSessionErrorCarriesDegradedAndRecovery() {
        let degraded = Degraded(stage: .authenticate, reason: "候选 token 全被拒（HTTP 401）")
        let notReady = DshSessionError.dshNotReady(degraded)
        XCTAssertEqual(notReady.degraded, degraded)
        XCTAssertEqual(notReady.recovery, .retryDsh)
        XCTAssertEqual(notReady.errorDescription, "SSH 已连、dsh 未就绪：候选 token 全被拒（HTTP 401）")

        let dead = DshSessionError.sshUnavailable(reason: "通道已关闭")
        XCTAssertNil(dead.degraded)
        XCTAssertEqual(dead.recovery, .rebuildStack)
        XCTAssertEqual(dead.errorDescription, "SSH 连接不可用：通道已关闭")

        let none = DshSessionError.notConnected
        XCTAssertNil(none.degraded)
        XCTAssertEqual(none.recovery, .connect)
        XCTAssertEqual(none.errorDescription, "SSH 尚未连接")
    }

    /// 首连的重试判定只认「降级 + 隧道类」：其它错误一律直接上抛。
    func testTunnelProblemRoutingOverSessionErrors() {
        XCTAssertTrue(DshSession.isTunnelProblem(
            DshSessionError.dshNotReady(Degraded(stage: .probe, reason: "x", isTunnelProblem: true))
        ))
        XCTAssertFalse(DshSession.isTunnelProblem(
            DshSessionError.dshNotReady(Degraded(stage: .authenticate, reason: "x", isTunnelProblem: false))
        ))
        XCTAssertFalse(DshSession.isTunnelProblem(DshSessionError.notConnected))
        XCTAssertFalse(DshSession.isTunnelProblem(PlainError(text: "boom")))
    }

    // MARK: 开 shell 日志里的状态

    func testSSHStateLabel() {
        XCTAssertEqual(DshFailureRules.sshState(connected: false, degraded: nil), "未连接")
        XCTAssertEqual(DshFailureRules.sshState(connected: true, degraded: nil), "已连")
        XCTAssertEqual(
            DshFailureRules.sshState(connected: true, degraded: Degraded(stage: .probe, reason: "x")),
            "已连/dsh 未就绪"
        )
        // 没连接时降级态不该存在，标签以「未连接」为准。
        XCTAssertEqual(
            DshFailureRules.sshState(connected: false, degraded: Degraded(stage: .probe, reason: "x")),
            "未连接"
        )
    }

    // MARK: 日志出口

    func testCoreLogForwardsToInstalledSink() {
        let box = LockedBox<[String]>([])
        CoreLog.shared.install { level, source, text in
            box.set(box.get() + ["\(level) \(source) \(text)"])
        }
        defer { CoreLog.shared.uninstall() }

        CoreLog.shared.log(.warn, "连接", "SSH 已就绪，dsh 未就绪：x")
        XCTAssertEqual(box.get(), ["warn 连接 SSH 已就绪，dsh 未就绪：x"])
    }
}

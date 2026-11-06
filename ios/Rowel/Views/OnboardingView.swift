/// First run, and the only screen most people will ever read.
///
/// The whole flow is one thing: type in the address of a dsh host and sign in
/// over SSH. Everything here exists to make that feel like one thing rather
/// than a setup procedure — no accounts, no relay, no helper to install on the
/// other end.

import SwiftUI

struct OnboardingView: View {
    @State private var connecting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Metrics.gap) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 46, weight: .thin))
                    .foregroundStyle(Palette.accent)
                Text(ClientIdentity.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, Metrics.gutter)
                Text("Your coding agent, in your pocket.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: Metrics.gap) {
                Promise(icon: "lock.shield", text: "Encrypted by SSH end to end. Traffic goes straight to your host.")
                Promise(icon: "person.crop.circle.badge.xmark", text: "No account. Nothing to sign up for.")
                Promise(icon: "network", text: "Your own dsh host. No relay in between, no helper to install.")
            }
            .padding(.horizontal, Metrics.gutter * 1.5)
            Spacer()
            VStack(spacing: Metrics.tight) {
                Button("连接 dsh 主机（SSH）") { connecting = true }
                    .buttonStyle(PrimaryButtonStyle())
                Text("Takes about a minute.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Text(ClientIdentity.buildStamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.gutter)
        }
        // 连上之后这一层就是工作区：用全屏覆盖，别让下滑手势把人拽回首页。
        .fullScreenCover(isPresented: $connecting) { SSHConnectView() }
    }
}

private struct Promise: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gap) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

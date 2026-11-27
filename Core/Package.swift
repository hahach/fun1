// swift-tools-version:5.9
import PackageDescription

// 平台中立的传输与协议层。只允许依赖 Foundation / swift-crypto / Citadel（SSH）
// 一类在 Linux 上可编译的库：这里的单测在 ubuntu runner 上跑（1x 分钟），
// macOS runner 只用来出包。
let package = Package(
    name: "DshClientCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DshClientCore", targets: ["DshClientCore"]),
        .executable(name: "dsh-probe", targets: ["dsh-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // 与 Citadel 同一个 fork，用于 direct-tcpip 通道类型（本地转发）。
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
    ],
    targets: [
        .target(name: "DshClientCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
        ]),
        .executableTarget(name: "dsh-probe", dependencies: ["DshClientCore"]),
        .testTarget(name: "DshClientCoreTests", dependencies: ["DshClientCore"]),
    ]
)

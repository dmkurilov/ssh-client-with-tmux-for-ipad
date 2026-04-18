// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ssh-client-with-tmux-for-ipad",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SSHConfig", targets: ["SSHConfig"]),
    ],
    targets: [
        .target(
            name: "SSHConfig",
            path: "Sources/SSHConfig",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "SSHConfigTests",
            dependencies: ["SSHConfig"],
            path: "Tests/SSHConfigTests",
            exclude: ["README.md"]
        ),
    ]
)

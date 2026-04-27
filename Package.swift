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
        .library(name: "TmuxCC", targets: ["TmuxCC"]),
        .library(name: "ColorSchemes", targets: ["ColorSchemes"]),
        .library(name: "SSHCore", targets: ["SSHCore"]),
        .library(name: "TerminalKit", targets: ["TerminalKit"]),
        .library(name: "SSHKnownHosts", targets: ["SSHKnownHosts"]),
    ],
    dependencies: [
        // SSHCore deps. If SPM cannot resolve a version, check the
        // upstream release tags and adjust the `from:` lower bound.
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.10.0"),
        // TerminalKit dep — SwiftTerm renders ANSI bytes into a UIView.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.3.0"),
        // SSHKnownHosts uses HMAC-SHA1 to match hashed-host entries.
        // swift-crypto is already in the transitive graph via Citadel;
        // this just promotes it to a direct dep.
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
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
        .target(
            name: "TmuxCC",
            path: "Sources/TmuxCC",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "TmuxCCTests",
            dependencies: ["TmuxCC"],
            path: "Tests/TmuxCCTests",
            exclude: ["README.md"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "ColorSchemes",
            path: "Sources/ColorSchemes",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "ColorSchemesTests",
            dependencies: ["ColorSchemes"],
            path: "Tests/ColorSchemesTests"
        ),
        .target(
            name: "SSHCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Sources/SSHCore"
        ),
        .target(
            name: "TerminalKit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/TerminalKit"
        ),
        .target(
            name: "SSHKnownHosts",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/SSHKnownHosts"
        ),
        .testTarget(
            name: "SSHKnownHostsTests",
            dependencies: ["SSHKnownHosts"],
            path: "Tests/SSHKnownHostsTests"
        ),
    ]
)

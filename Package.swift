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
    ],
    dependencies: [
        // De-risking step: only `SSHCore` uses this for now. If SPM cannot
        // resolve the version, check https://github.com/orlandos-nl/Citadel
        // /releases and adjust the `from:` lower bound.
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.10.0"),
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
    ]
)

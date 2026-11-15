// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileVault",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileVaultCore", targets: ["FileVaultCore"]),
        .executable(name: "FileVaultApp", targets: ["FileVaultApp"]),
    ],
    targets: [
        .target(
            name: "FileVaultCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FileVaultApp",
            dependencies: ["FileVaultCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FileVaultTests",
            dependencies: ["FileVaultCore", "FileVaultApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ColimaX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ColimaX",
            path: "Sources/ColimaX",
            // In-memory fakes (Sources/ColimaX/Testing) for `swift test`; release builds never include them.
            swiftSettings: [.define("COLIMAX_UI_TESTING", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "ColimaXTests",
            dependencies: ["ColimaX"],
            path: "Tests/ColimaXTests"
        ),
    ]
)

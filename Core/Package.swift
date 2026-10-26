// swift-tools-version:5.9
import PackageDescription

// KongFetchCore: the search engine of KongFetch, independent of AppKit.
// - KongFetchCore: name index, matching, persistence, change watching.
// - KongFetchLegacy32: a verbatim copy of 3.2's matching/scanning code,
//   kept only as the reference that tests and benchmarks compare against.
// - KongFetchTestSupport: synthetic file trees shared by tests and kfbench.
// - kfbench: command-line benchmark (`swift run -c release kfbench`).
let package = Package(
    name: "KongFetchCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KongFetchCore", targets: ["KongFetchCore"]),
        .executable(name: "kfbench", targets: ["kfbench"]),
    ],
    targets: [
        .target(name: "KongFetchCore"),
        .target(name: "KongFetchLegacy32"),
        .target(name: "KongFetchTestSupport"),
        .executableTarget(
            name: "kfbench",
            dependencies: ["KongFetchCore", "KongFetchLegacy32", "KongFetchTestSupport"]
        ),
        .testTarget(
            name: "KongFetchCoreTests",
            dependencies: ["KongFetchCore", "KongFetchLegacy32", "KongFetchTestSupport"]
        ),
    ]
)

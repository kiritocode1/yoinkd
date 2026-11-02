// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YoinksCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "YoinksCore", targets: ["YoinksCore"])],
    targets: [
        .target(name: "YoinksCore"),
        .testTarget(name: "YoinksCoreTests", dependencies: ["YoinksCore"])
    ]
)

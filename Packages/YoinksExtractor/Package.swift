// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YoinksExtractor",
    platforms: [.iOS(.v17)],
    products: [.library(name: "ExtractorBridge", targets: ["ExtractorBridge"])],
    targets: [
        .binaryTarget(name: "Python", path: "Vendor/Python.xcframework"),
        .target(name: "QuickJS", path: "Sources/QuickJS", exclude: ["LICENSE"], sources: ["quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c"], publicHeadersPath: "include", cSettings: [.define("_GNU_SOURCE"), .define("QUICKJS_NG_BUILD")]),
        .target(name: "ExtractorBridge", dependencies: ["Python", "QuickJS"], path: "Sources/ExtractorBridge", publicHeadersPath: "include")
    ]
)

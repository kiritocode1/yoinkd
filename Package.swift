// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
import Foundation

struct IOSSDKSettings: Decodable {
    let version: String

    enum CodingKeys: String, CodingKey {
        case version = "Version"
    }
}

let swiftPMDirectory = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
    URL(fileURLWithPath: $0).appendingPathComponent("swiftpm")
} ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swiftpm")
let sdkSettingsURL = swiftPMDirectory.appendingPathComponent(
    "swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.json"
)
let iosSDKVersion = try JSONDecoder().decode(IOSSDKSettings.self, from: Data(contentsOf: sdkSettingsURL)).version

// The Linux linker otherwise records the deployment target as the SDK version.
let xtoolLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-Xlinker", "-platform_version", "-Xlinker", "ios",
        "-Xlinker", "17.0", "-Xlinker", iosSDKVersion
    ], .when(platforms: [.iOS]))
]
#else
let xtoolLinkerSettings: [LinkerSetting] = []
#endif

let package = Package(
    name: "iYoinks",
    platforms: [.iOS(.v17)],
    products: [.library(name: "iYoinks", targets: ["iYoinks"])],
    dependencies: [.package(path: "Packages/YoinksCore"), .package(path: "Packages/YoinksExtractor"), .package(path: "Vendor/SwiftFFmpeg-iOS")],
    targets: [
        .target(
            name: "iYoinks",
            dependencies: [.product(name: "YoinksCore", package: "YoinksCore"), .product(name: "ExtractorBridge", package: "YoinksExtractor"), .product(name: "SwiftFFmpeg", package: "SwiftFFmpeg-iOS")],
            path: "iYoinks",
            exclude: ["Info.plist", "Assets.xcassets"],
            resources: [.copy("AppResources")],
            linkerSettings: xtoolLinkerSettings
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GemmaFind",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GemmaFind", targets: ["GemmaFind"]),
        .executable(name: "gemmafind-cli", targets: ["gemmafind-cli"]),
    ],
    targets: [
        // LiteRT-LM v0.18.0 prebuilt runtime (Metal GPU backend statically linked).
        // The Swift wrapper in Vendor/LiteRTLM is copied verbatim from the v0.18.0 tag
        // (Apache 2.0); depending on the git repo directly would clone several GB of history.
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM_mac.xcframework.zip",
            checksum: "5f6ee68d95eeccb084c6e66d5ee47255e3020fa0fb29696dd0301ae26d6cfb4f"
        ),
        .target(
            name: "LiteRTLM",
            dependencies: ["CLiteRTLM_mac"],
            path: "Vendor/LiteRTLM",
            exclude: ["LICENSE"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "GemmaFindCore",
            dependencies: ["LiteRTLM"],
            path: "Sources/GemmaFindCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(
            name: "GemmaFind",
            dependencies: ["GemmaFindCore"],
            path: "Sources/GemmaFind",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Quartz"),
                .linkedFramework("AVKit"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "gemmafind-cli",
            dependencies: ["GemmaFindCore"],
            path: "Sources/gemmafind-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GemmaFindTests",
            dependencies: ["GemmaFindCore"],
            path: "Tests/GemmaFindTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

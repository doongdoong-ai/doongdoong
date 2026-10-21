// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sori",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BungBungi", targets: ["SoriApp"]), .library(name: "SoriCore", targets: ["SoriCore"]),
               .executable(name: "DoongdoongTranscribe", targets: ["DoongdoongTranscribe"])],
    dependencies: [.package(url: "https://github.com/doongdoong-ai/transcription-core.git", exact: "0.1.0")],
    targets: [
        .target(name: "SoriCore"),
        .target(name: "SoriSpeech", dependencies: ["SoriCore", .product(name: "DoongdoongTranscription", package: "transcription-core")], resources: [.copy("Resources")]),
        .executableTarget(name: "DoongdoongTranscribe", dependencies: ["SoriSpeech", "SoriCore", .product(name: "DoongdoongTranscription", package: "transcription-core")]),
        .executableTarget(name: "SoriApp", dependencies: ["SoriCore", "SoriSpeech", .product(name: "DoongdoongTranscription", package: "transcription-core")], resources: [.copy("Resources")]),
        .testTarget(name: "SoriSpeechTests", dependencies: ["SoriSpeech", "SoriCore", .product(name: "DoongdoongTranscription", package: "transcription-core")]),
        .testTarget(name: "SoriCoreTests", dependencies: ["SoriCore"]),
        .testTarget(name: "SoriPipelineTests", dependencies: ["SoriApp", "SoriCore", .product(name: "DoongdoongTranscription", package: "transcription-core")])
    ],
    swiftLanguageModes: [.v5]
)

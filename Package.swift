// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sori",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BungBungi", targets: ["SoriApp"]), .library(name: "SoriCore", targets: ["SoriCore"]),
               .executable(name: "DoongdoongTranscribe", targets: ["DoongdoongTranscribe"])],
    targets: [
        .target(name: "SoriCore"),
        .target(name: "SoriSpeech", dependencies: ["SoriCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "DoongdoongTranscribe", dependencies: ["SoriSpeech", "SoriCore"]),
        .executableTarget(name: "SoriApp", dependencies: ["SoriCore", "SoriSpeech"], resources: [.copy("Resources")]),
        .testTarget(name: "SoriSpeechTests", dependencies: ["SoriSpeech", "SoriCore"]),
        .testTarget(name: "SoriCoreTests", dependencies: ["SoriCore"]),
        .testTarget(name: "SoriPipelineTests", dependencies: ["SoriApp", "SoriCore"])
    ],
    swiftLanguageModes: [.v5]
)

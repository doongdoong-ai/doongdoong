// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sori",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BungBungi", targets: ["SoriApp"]), .library(name: "SoriCore", targets: ["SoriCore"])],
    targets: [
        .target(name: "SoriCore"),
        .executableTarget(name: "SoriApp", dependencies: ["SoriCore"], resources: [.copy("Resources")]),
        .testTarget(name: "SoriCoreTests", dependencies: ["SoriCore"]),
        .testTarget(name: "SoriPipelineTests", dependencies: ["SoriApp", "SoriCore"])
    ],
    swiftLanguageModes: [.v5]
)

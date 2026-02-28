// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FFmpegLocal",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(name: "Libavcodec", targets: ["Libavcodec"]),
        .library(name: "Libavformat", targets: ["Libavformat"]),
        .library(name: "Libavutil", targets: ["Libavutil"])
    ],
    targets: [
        .binaryTarget(name: "Libavcodec", path: "Artifacts/Libavcodec.xcframework"),
        .binaryTarget(name: "Libavformat", path: "Artifacts/Libavformat.xcframework"),
        .binaryTarget(name: "Libavutil", path: "Artifacts/Libavutil.xcframework")
    ]
)

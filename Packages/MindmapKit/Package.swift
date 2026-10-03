// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MindmapKit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MindmapCore", targets: ["MindmapCore"]),
    .library(name: "MindmapGraph", targets: ["MindmapGraph"]),
    .executable(name: "mindmap-preview", targets: ["mindmap-preview"]),
  ],
  targets: [
    .target(name: "MindmapCore"),
    .target(name: "MindmapGraph", dependencies: ["MindmapCore"]),
    .executableTarget(name: "mindmap-preview", dependencies: ["MindmapCore", "MindmapGraph"]),
    .testTarget(name: "MindmapCoreTests", dependencies: ["MindmapCore"]),
  ]
)

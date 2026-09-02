// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "DevSift",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "DevSiftCore", targets: ["DevSiftCore"]),
    .executable(name: "devsift", targets: ["DevSiftCLI"]),
    .executable(name: "DevSiftApp", targets: ["DevSiftApp"]),
  ],
  targets: [
    .target(name: "DevSiftCore"),
    .executableTarget(
      name: "DevSiftCLI",
      dependencies: ["DevSiftCore"]
    ),
    .executableTarget(
      name: "DevSiftApp",
      dependencies: ["DevSiftCore"]
    ),
    .testTarget(
      name: "DevSiftCoreTests",
      dependencies: ["DevSiftCore"]
    ),
    .testTarget(
      name: "DevSiftCLITests",
      dependencies: ["DevSiftCLI", "DevSiftCore"]
    ),
    .testTarget(
      name: "DevSiftAppTests",
      dependencies: ["DevSiftApp", "DevSiftCore"]
    ),
  ]
)

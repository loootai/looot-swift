// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Looot",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "Looot", targets: ["Looot"]),
    ],
    targets: [
        .target(name: "Looot"),
        .testTarget(name: "LoootTests", dependencies: ["Looot"]),
    ]
)

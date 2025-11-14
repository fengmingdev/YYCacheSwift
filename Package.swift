// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "YYCacheSwift",
    platforms: [
        .iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6)
    ],
    products: [
        .library(name: "YYCacheSwift", targets: ["YYCacheSwift"])
    ],
    targets: [
        .target(
            name: "YYCacheSwift",
            path: "Sources/YYCacheSwift",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "YYCacheSwiftTests",
            dependencies: ["YYCacheSwift"],
            path: "Tests/YYCacheSwiftTests"
        )
    ]
)

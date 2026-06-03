// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vagalume",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/waydabber/AppleSiliconDDC.git", revision: "97af3818b9803e51412fb50cac1506db1d73b5bf"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "Vagalume",
            dependencies: [
                .product(name: "AppleSiliconDDC", package: "AppleSiliconDDC"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreDisplay"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(
            name: "VagalumeTests",
            dependencies: ["Vagalume"]
        ),
    ]
)

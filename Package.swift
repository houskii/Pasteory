// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pasteory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pasteory", targets: ["Pasteory"]),
        .library(name: "PasteoryCore", targets: ["PasteoryCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(
            name: "PasteoryCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Pasteory",
            dependencies: ["PasteoryCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "PasteoryBenchmark",
            dependencies: ["PasteoryCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "PasteoryCoreTests",
            dependencies: ["PasteoryCore", "Pasteory"]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pasteory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pasteory", targets: ["Pasteory"]),
        .library(name: "PasteoryCore", targets: ["PasteoryCore"])
    ],
    targets: [
        .target(
            name: "PasteoryCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Pasteory",
            dependencies: ["PasteoryCore"],
            linkerSettings: [
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
            dependencies: ["PasteoryCore"]
        )
    ]
)

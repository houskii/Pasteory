// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Passte",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Passte", targets: ["Passte"]),
        .library(name: "PassteCore", targets: ["PassteCore"])
    ],
    targets: [
        .target(
            name: "PassteCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Passte",
            dependencies: ["PassteCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookUI")
            ]
        ),
        .executableTarget(
            name: "PassteBenchmark",
            dependencies: ["PassteCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "PassteCoreTests",
            dependencies: ["PassteCore"]
        )
    ]
)

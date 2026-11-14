// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
let intelligenceCrypto: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let intelligenceCrypto: [Target.Dependency] = []
#endif

let intelligenceTargets: [Target] = [
    .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
    .target(name: "PasteoryAI", dependencies: ["CZlib"] + intelligenceCrypto),
    .testTarget(name: "PasteoryAITests", dependencies: ["PasteoryAI"])
]

#if os(Linux)
let package = Package(
    name: "Pasteory",
    products: [.library(name: "PasteoryAI", targets: ["PasteoryAI"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto", from: "3.0.0")],
    targets: intelligenceTargets
)
#else
let package = Package(
    name: "Pasteory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pasteory", targets: ["Pasteory"]),
        .library(name: "PasteoryCore", targets: ["PasteoryCore"]),
        .library(name: "PasteoryAI", targets: ["PasteoryAI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(
            name: "PasteoryCore",
            dependencies: ["PasteoryAI"],
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Pasteory",
            dependencies: ["PasteoryCore", "PasteoryAI", .product(name: "Sparkle", package: "Sparkle")],
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
    ] + intelligenceTargets
)
#endif

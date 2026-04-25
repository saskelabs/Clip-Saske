// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipSaske",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClipSaske", targets: ["ClipSaske"])
    ],
    targets: [
        .executableTarget(
            name: "ClipSaske",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)

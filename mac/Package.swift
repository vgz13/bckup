// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BCKUP",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BCKUP",
            path: "Sources/Amanin",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)

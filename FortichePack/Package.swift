// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FortichePack",
    // macOS is listed only so `swift test` runs on the host; the apps target iOS/watchOS 27.
    platforms: [.iOS("27.0"), .watchOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "FortichePack", targets: ["FortichePack"])
    ],
    targets: [
        .target(
            name: "FortichePack",
            resources: [.process("ExerciseLibrary/Resources")]
        ),
        .testTarget(name: "FortichePackTests", dependencies: ["FortichePack"]),
    ]
)

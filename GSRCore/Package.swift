// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GSRCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GSRCore", targets: ["GSRCore"]),
               .executable(name: "GSRApp", targets: ["GSRApp"]),
               .executable(name: "GSRMidiAgent", targets: ["GSRMidiAgent"])],
    targets: [
        .target(name: "GSRCore"),
        .executableTarget(name: "GSRApp", dependencies: ["GSRCore"]),
        .executableTarget(name: "GSRMidiAgent", dependencies: ["GSRCore"]),
        .testTarget(name: "GSRCoreTests", dependencies: ["GSRCore"],
                    resources: [.copy("Fixtures")]),
    ]
)

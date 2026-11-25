// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GSRCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GSRCore", targets: ["GSRCore"]),
               .executable(name: "GSRApp", targets: ["GSRApp"]),
               .executable(name: "GSRMidiAgent", targets: ["GSRMidiAgent"])],
    targets: [
        .target(name: "CGSRRing"),
        .target(name: "GSRCore", dependencies: ["CGSRRing"]),
        .executableTarget(name: "GSRApp", dependencies: ["GSRCore", "CGSRRing"]),
        .executableTarget(name: "GSRMidiAgent", dependencies: ["GSRCore"]),
        .testTarget(name: "GSRCoreTests", dependencies: ["GSRCore"],
                    resources: [.copy("Fixtures")]),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GSRCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GSRCore", targets: ["GSRCore"]),
               .executable(name: "GSRApp", targets: ["GSRApp"])],
    targets: [
        .target(name: "GSRCore"),
        .executableTarget(name: "GSRApp", dependencies: ["GSRCore"]),
        .testTarget(name: "GSRCoreTests", dependencies: ["GSRCore"],
                    resources: [.copy("Fixtures")]),
    ]
)

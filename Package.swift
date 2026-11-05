// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PinWhere",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PinWhere", targets: ["PinWhere"])],
    targets: [
        .target(name: "PinWhereCore"),
        .executableTarget(name: "PinWhere", dependencies: ["PinWhereCore"]),
        .testTarget(name: "PinWhereCoreTests", dependencies: ["PinWhereCore"])
    ]
)

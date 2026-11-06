// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RouteBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RouteBar", targets: ["RouteBar"]),
        .executable(name: "RouteBarHelper", targets: ["RouteBarHelper"]),
        .executable(name: "routebarctl", targets: ["RouteBarCLI"])
    ],
    targets: [
        .target(name: "RouteBarCore", resources: [.process("Resources")]),
        .executableTarget(name: "RouteBar", dependencies: ["RouteBarCore"]),
        .executableTarget(name: "RouteBarHelper", dependencies: ["RouteBarCore"]),
        .executableTarget(name: "RouteBarCLI", dependencies: ["RouteBarCore"]),
        .testTarget(name: "RouteBarCoreTests", dependencies: ["RouteBarCore"])
    ]
)

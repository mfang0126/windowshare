// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowShare",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WindowShareHost", targets: ["WindowShareHost"])
    ],
    targets: [
        .executableTarget(
            name: "WindowShareHost",
            path: "host/Sources"
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pinglet",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Pinglet", targets: ["Pinglet"])
    ],
    targets: [
        .executableTarget(
            name: "Pinglet",
            path: "Sources/Pinglet",
            resources: [
                .process("Resources")
            ]
        )
    ]
)

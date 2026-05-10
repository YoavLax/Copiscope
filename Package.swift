// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentScope",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentScope",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            path: "AgentScope",
            exclude: ["Info.plist", "AgentScope.entitlements"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AgentScopeTests",
            dependencies: ["AgentScope"],
            path: "AgentScopeTests"
        ),
    ]
)

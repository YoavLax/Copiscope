// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Copiscope",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Copiscope",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            path: "Copiscope",
            exclude: ["Info.plist", "Copiscope.entitlements"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "CopIscopeTests",
            dependencies: ["Copiscope"],
            path: "CopIscopeTests"
        ),
    ]
)

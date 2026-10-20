// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "HotSync",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // file checks and pilot-xfer transcript: no UI, unit-tested
        .target(
            name: "HotSyncCore",
            path: "Sources/HotSyncCore"
        ),
        .testTarget(
            name: "HotSyncCoreTests",
            dependencies: ["HotSyncCore"],
            path: "Tests/HotSyncCoreTests"
        ),
        // PIM sync: Palm database container and record codecs (Calendar,
        // Contacts, Tasks), no UI, unit-tested against golden .pdb fixtures
        .target(
            name: "PalmSync",
            path: "Sources/PalmSync"
        ),
        .testTarget(
            name: "PalmSyncTests",
            dependencies: ["PalmSync"],
            path: "Tests/PalmSyncTests",
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "HotSync",
            dependencies: ["HotSyncCore"],
            path: "Sources/HotSync",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)

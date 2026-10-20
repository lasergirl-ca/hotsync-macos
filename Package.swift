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
            dependencies: ["HotSyncCore"],   // the session events of hotsync-session
            path: "Sources/PalmSync"
        ),
        .testTarget(
            name: "PalmSyncTests",
            // HotSyncCore: the install queue's file check must accept what the builder writes
            dependencies: ["PalmSync", "HotSyncCore"],
            path: "Tests/PalmSyncTests",
            resources: [.copy("Fixtures")]
        ),
        // Phase 2 of the PIM sync: Calendar.app to CalendarDB-PDat, as a
        // command-line tool; the Info.plist is linked in for the Calendar
        // access prompt
        .executableTarget(
            name: "palmsync-calendar",
            dependencies: ["PalmSync"],
            path: "Sources/palmsync-calendar",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", Context.packageDirectory + "/Resources/palmsync-calendar-Info.plist"]),
            ]
        ),
        // Live check of the record bridge against a Palm: reads a database
        // through hotsync-session and round-trips it through the codecs
        .executableTarget(
            name: "palmsync-probe",
            dependencies: ["PalmSync", "HotSyncCore"],
            path: "Sources/palmsync-probe"
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

// swift-tools-version: 6.0
// Shared dynamic libraries for ALWM + plugins.
// Must live in a *separate* package so SPM does not statically merge them into each
// plugin dylib (same-package dynamic products still get duplicated at dlopen).

import PackageDescription

let package = Package(
    name: "AlwmShared",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AlwmPluginAPI", type: .dynamic, targets: ["AlwmPluginAPI"]),
        .library(name: "AlwmL10n", type: .dynamic, targets: ["AlwmL10n"]),
        .library(name: "AlwmStatsKit", type: .dynamic, targets: ["AlwmStatsKit"]),
        // Header-only clang module. Do NOT set type: .dynamic — SPM cannot build a
        // C target as both a dynamic product and a static dep of plugins/API.
        // package.sh synthesizes libAlwmPluginABI.dylib when SPM omits it (release).
        .library(name: "AlwmPluginABI", targets: ["AlwmPluginABI"])
    ],
    targets: [
        .target(
            name: "AlwmPluginABI",
            path: "Sources/AlwmPluginABI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AlwmPluginAPI",
            dependencies: ["AlwmPluginABI"],
            path: "Sources/AlwmPluginAPI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "AlwmL10n",
            path: "Sources/AlwmL10n",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "AlwmStatsKit",
            path: "Sources/AlwmStatsKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("IOBluetooth")
            ]
        )
    ]
)

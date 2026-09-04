// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ALWM",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ALWM", targets: ["AlwmApp"]),
        .executable(name: "alwmctl", targets: ["AlwmCtl"]),
        .library(name: "AlwmPluginAPI", type: .dynamic, targets: ["AlwmPluginAPI"]),
        .library(name: "SampleClockPlugin", type: .dynamic, targets: ["SampleClockPlugin"]),
        .library(name: "SteamPriceWatcherPlugin", type: .dynamic, targets: ["SteamPriceWatcherPlugin"]),
        .library(name: "GitHubPlugin", type: .dynamic, targets: ["GitHubPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0")
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
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "SampleClockPlugin",
            dependencies: ["AlwmPluginAPI", "AlwmPluginABI", "AlwmL10n"],
            path: "plugins/sample-clock",
            exclude: [
                "plugin.json",
                "README.md",
                "previews"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "SteamPriceWatcherPlugin",
            dependencies: ["AlwmPluginAPI", "AlwmPluginABI", "AlwmL10n"],
            path: "plugins/steam-price-watcher",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "Resources"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .target(
            name: "GitHubPlugin",
            dependencies: ["AlwmPluginAPI", "AlwmPluginABI", "AlwmL10n"],
            path: "plugins/github",
            exclude: [
                "plugin.json",
                "README.md"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .target(
            name: "AlwmIPC",
            path: "Sources/AlwmIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6)
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
            name: "Alwm",
            dependencies: [
                "AlwmIPC",
                "AlwmL10n",
                "AlwmPluginAPI",
                "AlwmPluginABI",
                .product(name: "TOML", package: "swift-toml")
            ],
            path: "Sources/Alwm",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "AlwmApp",
            dependencies: ["Alwm"],
            path: "Sources/AlwmApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AlwmCtl",
            dependencies: ["AlwmIPC"],
            path: "Sources/AlwmCtl",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AlwmTests",
            dependencies: ["Alwm", "AlwmIPC"],
            path: "Tests/AlwmTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)

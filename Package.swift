// swift-tools-version: 6.0

import PackageDescription

/// Shared modules live in `Packages/AlwmShared` so SPM links them as real dylibs.
/// Same-package dynamic products are still statically merged into plugin dylibs,
/// which duplicates ObjC class names and crashes when multiple plugins load.
let sharedAPI: Target.Dependency = .product(name: "AlwmPluginAPI", package: "AlwmShared")
let sharedABI: Target.Dependency = .product(name: "AlwmPluginABI", package: "AlwmShared")
let sharedL10n: Target.Dependency = .product(name: "AlwmL10n", package: "AlwmShared")
let sharedStats: Target.Dependency = .product(name: "AlwmStatsKit", package: "AlwmShared")

let package = Package(
    name: "ALWM",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ALWM", targets: ["AlwmApp"]),
        .executable(name: "alwmctl", targets: ["AlwmCtl"]),
        .library(name: "SampleClockPlugin", type: .dynamic, targets: ["SampleClockPlugin"]),
        .library(name: "SteamPriceWatcherPlugin", type: .dynamic, targets: ["SteamPriceWatcherPlugin"]),
        .library(name: "GitHubPlugin", type: .dynamic, targets: ["GitHubPlugin"]),
        .library(name: "StatsCPUPlugin", type: .dynamic, targets: ["StatsCPUPlugin"]),
        .library(name: "StatsMemoryPlugin", type: .dynamic, targets: ["StatsMemoryPlugin"]),
        .library(name: "StatsNetworkPlugin", type: .dynamic, targets: ["StatsNetworkPlugin"]),
        .library(name: "StatsBatteryPlugin", type: .dynamic, targets: ["StatsBatteryPlugin"]),
        .library(name: "StatsDiskPlugin", type: .dynamic, targets: ["StatsDiskPlugin"]),
        .library(name: "StatsGPUPlugin", type: .dynamic, targets: ["StatsGPUPlugin"]),
        .library(name: "StatsSensorsPlugin", type: .dynamic, targets: ["StatsSensorsPlugin"]),
        .library(name: "StatsFansPlugin", type: .dynamic, targets: ["StatsFansPlugin"]),
        .library(name: "StatsBluetoothPlugin", type: .dynamic, targets: ["StatsBluetoothPlugin"]),
        .library(name: "NowPlayingPlugin", type: .dynamic, targets: ["NowPlayingPlugin"]),
        .library(name: "StatsUptimePlugin", type: .dynamic, targets: ["StatsUptimePlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
        .package(path: "Packages/AlwmShared")
    ],
    targets: [
        .target(
            name: "SampleClockPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n],
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
            dependencies: [sharedAPI, sharedABI, sharedL10n],
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
            dependencies: [sharedAPI, sharedABI, sharedL10n],
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
            name: "StatsCPUPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-cpu",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsMemoryPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-memory",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsNetworkPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-network",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsBatteryPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-battery",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsDiskPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-disk",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsGPUPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-gpu",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsSensorsPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-sensors",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsFansPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-fans",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsBluetoothPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-bluetooth",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOBluetooth")
            ]
        ),
        .target(
            name: "NowPlayingPlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/now-playing",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "StatsUptimePlugin",
            dependencies: [sharedAPI, sharedABI, sharedL10n, sharedStats],
            path: "plugins/stats-uptime",
            exclude: [
                "plugin.json",
                "README.md",
                "previews",
                "l10n"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
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
            name: "Alwm",
            dependencies: [
                "AlwmIPC",
                sharedL10n,
                sharedAPI,
                sharedABI,
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

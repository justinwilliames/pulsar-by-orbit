// swift-tools-version: 6.1
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "CaldwellDashboard",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Hummingbird — SSWG-endorsed lightweight HTTP server. Used to host
        // the local API (/speak, /queue, /cache, /settings, /events, …)
        // inside the app process so we can retire the standalone Python
        // daemon. Keeping the HTTP surface preserves say.sh + Stop hook
        // compatibility while collapsing to a single binary.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CaldwellDashboard",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate",
                              "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", "\(packageDir)/Info.plist"])
            ]
        ),
    ]
)

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
        // Sparkle — in-app auto-update. Re-added after the 0.2.0 removal:
        // the prior attempt dyld-crashed because the framework was linked
        // but never embedded at Contents/Frameworks with a matching rpath.
        // build-caldwell-app.sh + package-dmg.yml now embed + sign it, and
        // the -rpath linker flag below bakes @executable_path/../Frameworks
        // into the binary so dyld resolves the embedded framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "CaldwellDashboard",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            resources: [
                .copy("Resources/AppIcon.icns"),
                // OrbitLogo images — copied as plain PNGs to the resource bundle,
                // then explicitly placed in Contents/Resources/ by build-caldwell-app.sh
                // so Bundle.main can find them via NSImage(named:).
                .copy("Resources/OrbitLogo.png"),
                .copy("Resources/OrbitLogo@2x.png"),
                .copy("Resources/OrbitLogo@3x.png"),
                // Pulsar robot base — one front-facing robot with a blank screen.
                // The procedural face (eyes/brows/mouth) is drawn live in SwiftUI
                // on top of this; placed in Contents/Resources/ by the build script.
                .copy("Resources/pulsar-base.png"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate",
                              "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", "\(packageDir)/Info.plist",
                              // Resolve the embedded Sparkle.framework at runtime
                              // from the .app bundle's Frameworks dir.
                              "-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
    ]
)

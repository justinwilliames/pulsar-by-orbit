// swift-tools-version: 6.1
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "CaldwellDashboard",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "CaldwellDashboard",
            path: "Sources",
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate",
                              "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", "\(packageDir)/Info.plist"])
            ]
        ),
    ]
)

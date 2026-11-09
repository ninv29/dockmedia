// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockMedia",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DockMedia",
            path: "Sources/DockMedia",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("ServiceManagement")]
        )
    ]
)

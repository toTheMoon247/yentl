// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "YentlShared",
    // iOS is the deployment platform for both apps.
    // macOS is declared so `swift build`/`swift test` (which run on the
    // macOS host) can resolve SwiftUI APIs in the shared package.
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "YentlShared", targets: ["YentlShared"]),
    ],
    targets: [
        .target(name: "YentlShared"),
        .testTarget(name: "YentlSharedTests", dependencies: ["YentlShared"]),
    ]
)

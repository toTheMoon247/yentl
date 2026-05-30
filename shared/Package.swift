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
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "YentlShared",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(name: "YentlSharedTests", dependencies: ["YentlShared"]),
    ]
)

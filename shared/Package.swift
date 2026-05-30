// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "YentlShared",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "YentlShared", targets: ["YentlShared"]),
    ],
    targets: [
        .target(name: "YentlShared"),
        .testTarget(name: "YentlSharedTests", dependencies: ["YentlShared"]),
    ]
)

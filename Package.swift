// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "R2ClientKit",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),
        .macOS(.v11),
        .tvOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "R2ClientKit",
            targets: ["R2ClientKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto-core.git", from: "7.9.0"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.10.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "R2ClientKit",
            dependencies: [
                .product(name: "SotoCore", package: "soto-core"),
                .product(name: "SotoS3", package: "soto")
            ]
        ),
        .testTarget(
            name: "R2ClientKitTests",
            dependencies: ["R2ClientKit"]
        ),
    ]
)

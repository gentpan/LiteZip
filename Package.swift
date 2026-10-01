// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LiteZip",
    platforms: [.macOS(.v13)],
    products: [.library(name: "LiteZipCore", targets: ["LiteZipCore"])],
    targets: [
        .target(name: "LiteZipCore"),
        .testTarget(name: "LiteZipCoreTests", dependencies: ["LiteZipCore"], resources: [.copy("Fixtures")])
    ]
)

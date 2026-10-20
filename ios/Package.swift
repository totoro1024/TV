// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TVCore", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TVCore", type: .static, targets: ["TVCore"]), .executable(name: "TVCoreChecks", targets: ["TVCoreChecks"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.11.3")],
    targets: [.target(name: "TVCore", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]), .executableTarget(name: "TVCoreChecks", dependencies: ["TVCore"]), .testTarget(name: "TVCoreTests", dependencies: ["TVCore"])],
    swiftLanguageModes: [.v5]
)

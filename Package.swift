// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Courseflow",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "CourseflowCore", targets: ["CourseflowCore"])],
    targets: [
        .target(name: "CourseflowCore"),
        .testTarget(name: "CourseflowCoreTests", dependencies: ["CourseflowCore"])
    ]
)

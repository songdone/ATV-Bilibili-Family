// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FamilyCore",
    platforms: [.macOS(.v13), .tvOS(.v16)],
    products: [.library(name: "FamilyCore", targets: ["FamilyCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "FamilyCore", dependencies: ["CSQLite"]),
        .testTarget(name: "FamilyCoreTests", dependencies: ["FamilyCore", "CSQLite"])
    ]
)

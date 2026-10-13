// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Flit", targets: ["Flit"])],
    targets: [.executableTarget(name: "Flit", linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("Carbon")])],
    swiftLanguageModes: [.v5]
)

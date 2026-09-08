// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Slidebox",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Slidebox", targets: ["Slidebox"])],
    targets: [.executableTarget(name: "Slidebox")],
    swiftLanguageModes: [.v5]
)

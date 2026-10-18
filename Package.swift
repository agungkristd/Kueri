// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kueri",
    platforms: [.macOS("14.4")],
    targets: [
        .systemLibrary(name: "CPQ", path: "Sources/CPQ"),
        .systemLibrary(name: "COpenSSL", path: "Sources/COpenSSL"),
        .executableTarget(name: "Kueri", dependencies: ["CPQ", "COpenSSL"], path: "Sources/Kueri"),
    ]
)

// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SipBuddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SipBuddy", path: "Sources/SipBuddy")
    ]
)

// swift-tools-version: 5.9
import PackageDescription

// The manifest sits at the repository root so Swift Package Manager can add
// the SDK straight from the repository URL; the sources live under ios/.
//
// AccessorySetupKit (iOS 18) is not linked explicitly: `import AccessorySetupKit`
// auto-links it, and because every symbol we use from it is newer than the
// iOS 16 deployment target the linker loads the framework weakly
// (LC_LOAD_WEAK_DYLIB), so the package still launches on iOS 16 and 17.
//
// The module is PlugchoiceSDK and its main class Plugchoice: a module named
// Plugchoice would clash with an app whose own target (and so Swift module)
// is called Plugchoice, and the CocoaPods pod has the same name.
let package = Package(
    name: "PlugchoiceSDK",
    platforms: [.iOS(.v16)],
    products: [
        // Later products (PlugchoiceCharging) depend on this one, so
        // `import PlugchoiceSDK` keeps working for every app.
        .library(name: "PlugchoiceSDK", targets: ["PlugchoiceSDK"]),
    ],
    targets: [
        .target(
            name: "PlugchoiceSDK",
            path: "ios/Sources/PlugchoiceSDK"
        ),
        // iOS only (UIKit, WebKit): run with xcodebuild on a simulator, see ios/README.md.
        .testTarget(
            name: "PlugchoiceSDKTests",
            dependencies: ["PlugchoiceSDK"],
            path: "ios/Tests/PlugchoiceSDKTests",
            // Test-only certificates: test CAs standing in for a device's CA.
            resources: [.copy("Certificates")]
        ),
    ]
)

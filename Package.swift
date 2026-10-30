// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YapsSupport",
    defaultLocalization: "en",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "YapsSupport", targets: ["YapsSupport"]),
    ],
    targets: [
        .target(
            name: "YapsSupport",
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "YapsSupportTests",
            dependencies: ["YapsSupport"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

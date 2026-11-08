// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "QuickTranslate",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "QuickTranslate", targets: ["QuickTranslate"])],
  targets: [
    .target(name: "TranslationCore"),
    .executableTarget(name: "QuickTranslate", dependencies: ["TranslationCore"]),
    .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"]),
  ],
  swiftLanguageModes: [.v6]
)

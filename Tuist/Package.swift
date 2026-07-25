// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription
// Some transitive deps (e.g. swift-collections) don't declare an explicit `platforms:` minimum,
// which Tuist's SPM integration otherwise renders as MACOSX_DEPLOYMENT_TARGET 10.13 — below the
// 12.0 floor Xcode 27 enforces. Bump the floor for all SPM-generated targets.
let deploymentFloor: SettingsDictionary = [
    "MACOSX_DEPLOYMENT_TARGET": "13.0",
    "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
]
let packageSettings = PackageSettings(
    productTypes: [:],
    baseSettings: .settings(base: deploymentFloor),
    targetSettings: [
        // swift-collections doesn't declare `platforms:` in its own Package.swift, so Tuist bakes
        // a literal 10.13/12.0 into these two targets' own build settings — more specific than
        // (and so overriding) `baseSettings` above. Xcode 27 requires macOS >= 12.0.
        "InternalCollectionsUtilities": .settings(base: deploymentFloor),
        "OrderedCollections": .settings(base: deploymentFloor),
    ]
)
#endif

let package = Package(
    name: "EmberDependencies",
    dependencies: [
        // Tokenizer ONLY (Gemma SentencePiece). Pin exact; verify latest tag when executing.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.15")
    ]
)

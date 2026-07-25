import Foundation
import ProjectDescription

let deployment: DeploymentTargets = .multiplatform(iOS: "26.0", macOS: "26.0")
let appDestinations: Destinations = [.iPhone, .iPad, .mac]

// The EmbeddingGemma weights are gitignored dev assets fetched per machine (scripts/fetch_
// embeddinggemma.sh), so `Models/` is usually ABSENT — on contributor and CI checkouts, and on this
// one. Tuist cannot reference a path that does not exist, and manifests are plain Swift, so probe
// the filesystem and wire the weights in only when they are really there. `#filePath` anchors the
// probe to the repo root no matter what the working directory is.
//
// The layout is deliberate, NOT a plain glob. `Resources/**` walks INTO `EmbeddingGemma.mlpackage`
// (which is a directory) and fails generation outright: "Trying to add a file at path
// …/EmbeddingGemma.mlpackage/Data/model.bin to a build phase that hasn't been added to the
// project." So the package is listed as a single resource — Xcode's Core ML compiler turns it into
// `EmbeddingGemma.mlmodelc` at the bundle resources root — and `tokenizer/` is a folder reference
// so it survives as a DIRECTORY (AutoTokenizer needs a folder; a glob would flatten its files into
// the bundle root). `EmberApp.makeEmbedder()` looks resources up in exactly that shape.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let modelsDirectory = "Targets/Ember/Resources/Models"
let modelsArePresent = FileManager.default.fileExists(
    atPath: repoRoot.appendingPathComponent(modelsDirectory).path)

let emberResources: ResourceFileElements = modelsArePresent
    ? .resources([
        // Models is handled by the two entries below — keep it out of the glob so nothing is
        // bundled twice and so the glob never descends into the .mlpackage.
        .glob(pattern: "Targets/Ember/Resources/**",
              excluding: ["Targets/Ember/Resources/Models/**"]),
        .glob(pattern: "Targets/Ember/Resources/Models/EmbeddingGemma.mlpackage"),
        .folderReference(path: .relativeToRoot("Targets/Ember/Resources/Models/tokenizer")),
      ])
    : .resources([.glob(pattern: "Targets/Ember/Resources/**")])

let project = Project(
    name: "Ember",
    targets: [
        .target(
            name: "FoundationChatKit",
            destinations: appDestinations,
            product: .framework,
            bundleId: "dev.iosunpi.ember.kit",
            deploymentTargets: deployment,
            sources: ["Targets/FoundationChatKit/Sources/**"],
            // swift-transformers vends a single umbrella `Transformers` library product, so the
            // narrower `.external(name: "Tokenizers")` does not resolve — Tuist matches externals by
            // product name. Only the tokenizer is used; see README for the dormant-Hub caveat.
            dependencies: [.external(name: "Transformers")]
        ),
        .target(
            name: "FoundationChatKitTests",
            destinations: appDestinations,
            product: .unitTests,
            bundleId: "dev.iosunpi.ember.kit.tests",
            deploymentTargets: deployment,
            sources: ["Targets/FoundationChatKit/Tests/**"],
            dependencies: [.target(name: "FoundationChatKit")]
        ),
        .target(
            name: "Ember",
            destinations: appDestinations,
            product: .app,
            bundleId: "dev.iosunpi.ember",
            deploymentTargets: deployment,
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Ember",
                "CFBundleShortVersionString": "0.1",
                "CFBundleVersion": "1",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "UILaunchScreen": [:],
            ]),
            sources: ["Targets/Ember/Sources/**"],
            resources: emberResources,
            dependencies: [.target(name: "FoundationChatKit")]
        ),
        .target(
            name: "EmberTests",
            destinations: appDestinations,
            product: .unitTests,
            bundleId: "dev.iosunpi.ember.tests",
            deploymentTargets: deployment,
            sources: ["Targets/Ember/Tests/**"],
            dependencies: [.target(name: "Ember")]
        ),
    ]
)

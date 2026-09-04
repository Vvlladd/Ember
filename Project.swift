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
    // Tuist's DEFAULT scheme grouping (`.byNameSuffix`) is
    //     build: ["Implementation", "Interface", "Mocks", "Testing"]
    //     test:  ["Tests", "IntegrationTests", "UITests", "SnapshotTests"]
    //     run:   ["App", "Demo", "Example"]
    // (ProjectDescription 4.154.3). "Example" being a RUN suffix folds `EmberScopeExample` into the
    // `EmberScope` scheme as its run target, so it never gets one of its own — but the example needs its
    // own buildable scheme (`-scheme EmberScopeExample` is a documented gate), and the library's test
    // scheme should not have to build an app. The lists below are those defaults verbatim, with "Example"
    // — and nothing else — dropped from `run`.
    options: .options(automaticSchemesOptions: .enabled(targetSchemesGrouping: .byNameSuffix(
        build: ["Implementation", "Interface", "Mocks", "Testing"],
        test: ["Tests", "IntegrationTests", "UITests", "SnapshotTests"],
        run: ["App", "Demo"]))),
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
            dependencies: [.external(name: "Transformers"), .target(name: "EmberScope")]
        ),
        .target(
            name: "FoundationChatKitTests",
            destinations: appDestinations,
            product: .unitTests,
            bundleId: "dev.iosunpi.ember.kit.tests",
            deploymentTargets: deployment,
            sources: ["Targets/FoundationChatKit/Tests/**"],
            // The EmberScope integration test imports EmberScope directly.
            dependencies: [.target(name: "FoundationChatKit"), .target(name: "EmberScope")]
        ),
        .target(
            name: "EmberScope",
            destinations: appDestinations,
            product: .framework,
            bundleId: "dev.iosunpi.emberscope",
            deploymentTargets: deployment,
            sources: ["Targets/EmberScope/Sources/**"],
            settings: .settings(base: [
                // Keep the library adoptable by Swift-6-strict hosts even though this repo builds in
                // Swift 5 language mode (warnings here, errors there) — and make that real by failing
                // the build on any warning, so the promise cannot rot one warning at a time.
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
            ])
        ),
        .target(
            name: "EmberScopeTests",
            destinations: appDestinations,
            product: .unitTests,
            bundleId: "dev.iosunpi.emberscope.tests",
            deploymentTargets: deployment,
            sources: ["Targets/EmberScope/Tests/**"],
            dependencies: [.target(name: "EmberScope")],
            // The suite exercises the same concurrency surface a Swift-6 host would.
            settings: .settings(base: ["SWIFT_STRICT_CONCURRENCY": "complete"])
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
            dependencies: [.target(name: "FoundationChatKit"), .target(name: "EmberScope")]
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
        // The EmberScope example host — netfox's "example project" equivalent. It depends on
        // EmberScope ALONE (never FoundationChatKit): that dependency shape is the proof the library
        // drops into any Foundation Models app, so keep this list at one entry.
        .target(
            name: "EmberScopeExample",
            destinations: appDestinations,
            product: .app,
            bundleId: "dev.iosunpi.emberscope.example",
            deploymentTargets: deployment,
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "EmberScope Example",
                "CFBundleShortVersionString": "0.1",
                "CFBundleVersion": "1",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "UILaunchScreen": [:],
            ]),
            sources: ["Targets/EmberScopeExample/Sources/**"],
            dependencies: [.target(name: "EmberScope")]
        ),
    ]
)

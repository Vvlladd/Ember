import ProjectDescription

let deployment: DeploymentTargets = .multiplatform(iOS: "26.0", macOS: "26.0")
let appDestinations: Destinations = [.iPhone, .iPad, .mac]

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
            dependencies: []
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
            resources: ["Targets/Ember/Resources/**"],
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

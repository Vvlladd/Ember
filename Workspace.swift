import ProjectDescription

// The generated .xcodeproj files are git-ignored, so Xcode's "Update to recommended settings" cannot be
// answered with "Perform Changes" — Tuist would undo it on the next generate. Stamping LastUpgradeCheck
// here (plus the project-level `xcodeRecommended` settings in Project.swift) is the durable fix.
let workspace = Workspace(
    name: "Ember",
    projects: ["."],
    generationOptions: .options(lastXcodeUpgradeCheck: "27.0.0")
)

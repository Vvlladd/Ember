import SwiftUI
import EmberScope

/// macOS: the inspector lives in its own window (opened by the toolbar button and ⌘⇧E); the sheet
/// attached by `.emberScope()` is the iOS presentation. Shared with `ChatScreen`, so keep it internal.
let emberScopeWindowID = "emberscope"

/// The whole EmberScope integration an adopter writes, in one file: `start()` at launch, `.emberScope()`
/// once per scene, the Debug menu, and (on macOS) a window for the console. Everything is `#if DEBUG`,
/// mirroring `Targets/Ember/Sources/EmberApp.swift` — in Release this is a plain chat app.
@main
struct ExampleApp: App {
    @State private var model: ChatModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    init() {
        #if DEBUG
        // Must run BEFORE any session is created: the recorder is paused until `start()`, so a session
        // built earlier would never record its creation, tools or context snapshot. Hence the explicit
        // ordering here rather than a default value on the property.
        EmberScope.start()
        #endif
        _model = State(initialValue: ChatModel())
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            ChatScreen(model: model).emberScope()
            #else
            ChatScreen(model: model)
            #endif
        }
        #if DEBUG
        .commands {
            #if os(macOS)
            EmberScopeCommands { openWindow(id: emberScopeWindowID) }
            #else
            EmberScopeCommands()
            #endif
        }
        #endif
        #if DEBUG && os(macOS)
        Window("Ember Scope", id: emberScopeWindowID) {
            EmberScopeView()
        }
        .defaultSize(width: 960, height: 680)
        #endif
    }
}

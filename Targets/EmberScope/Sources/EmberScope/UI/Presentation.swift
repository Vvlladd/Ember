import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public extension View {
    /// Attach the inspector: a sheet bound to `EmberScope.store.isPresented`, opened by
    /// `EmberScope.present()` and — on iOS — by shaking the device.
    ///
    /// Attach this EXACTLY ONCE per scene: every copy binds the same `EmberScope.store.isPresented`,
    /// so two of them present two sheets for one shake.
    func emberScope() -> some View { modifier(EmberScopeModifier()) }
}

struct EmberScopeModifier: ViewModifier {
    @Bindable private var store: ScopeStore = EmberScope.store

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $store.isPresented) {
                EmberScopeView(store: store)
                #if os(iOS)
                    .presentationDetents([.large])
                #endif
            }
        #if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: .emberScopeShake)) { _ in
                EmberScope.present()   // `present()` carries the isEnabled guard; a PAUSED inspector still opens
            }
        #endif
    }
}

/// "Debug ▸ Ember Scope" (⌘⇧E). Pass an action to open a dedicated window instead of the sheet.
public struct EmberScopeCommands: Commands {
    let action: @MainActor () -> Void

    public init(action: @escaping @MainActor () -> Void = { EmberScope.present() }) {
        self.action = action
    }

    public var body: some Commands {
        CommandMenu("Debug") {
            // Defense in depth: even a host that forgot #if DEBUG never opens a disabled inspector.
            // `isEnabled`, not `isActive` — pausing recording must not disable the menu item.
            Button("Ember Scope") { if EmberScope.isEnabled { action() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}

#if canImport(UIKit)
public extension Notification.Name {
    /// Posted on shake. Observed by `.emberScope()`; observe it yourself for custom presentation.
    static let emberScopeShake = Notification.Name("dev.iosunpi.emberscope.shake")
}

#if DEBUG
/// DEBUG only: this overrides a UIKit method for EVERY window in the host app, which is fine for a
/// debug tool and not something to ship in Release — where `ScopeConfiguration.isEnabled` is false
/// anyway, so the notification could never open anything.
extension UIWindow {
    /// The standard SwiftUI shake hook: `motionEnded` is an Objective-C method, so overriding it in an
    /// extension is supported. Global for the app — acceptable for a debug tool.
    public override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake, EmberScope.isEnabled {
            NotificationCenter.default.post(name: .emberScopeShake, object: nil)
        }
    }
}
#endif
#endif

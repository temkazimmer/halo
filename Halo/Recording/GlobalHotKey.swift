import AppKit
import Carbon.HIToolbox

/// A system-wide start/stop shortcut.
///
/// Carbon's `RegisterEventHotKey` is deliberate, not legacy baggage: it needs no
/// entitlement and no Accessibility grant, and it works inside the sandbox.
/// `NSEvent.addGlobalMonitorForEvents` may appear to work on a development
/// machine because of cached TCC state, but is not supported for sandboxed apps.
///
/// Nothing here posts synthetic events — apps have been rejected under App Review
/// 2.4.5 for that.
@MainActor
final class GlobalHotKey {
    /// ⌥⌘R by default: unclaimed by the system and unlikely to collide.
    static let defaultKeyCode = UInt32(kVK_ANSI_R)
    static let defaultModifiers = UInt32(cmdKey | optionKey)

    // Opaque Carbon handles, touched only at init and deinit. `deinit` is
    // nonisolated under Swift 6 and cannot reach main-actor state, and these
    // are not values anything else races on.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private let onPressed: () -> Void

    init?(
        keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
        modifiers: UInt32 = GlobalHotKey.defaultModifiers,
        onPressed: @escaping () -> Void
    ) {
        self.onPressed = onPressed

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        // The C callback cannot capture, so identity travels as userData.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            context,
            &handlerRef)
        guard installStatus == noErr else { return nil }

        // 'HALO' as a four-character code, which is what Carbon expects.
        let identifier = EventHotKeyID(signature: 0x4841_4C4F, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)

        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    fileprivate func fire() {
        onPressed()
    }

    /// How the shortcut should read in a menu.
    static var displayName: String { "⌥⌘R" }
}

/// Carbon delivers hot-key events on the main run loop.
private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}

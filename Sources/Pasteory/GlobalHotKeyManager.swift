import Carbon
import Foundation

private let pasteoryHotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
    Task { @MainActor in GlobalHotKeyManager.active?.fire() }
    return noErr
}

@MainActor
final class GlobalHotKeyManager {
    static weak var active: GlobalHotKeyManager?
    private var reference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?
    var onPress: (() -> Void)?
    private(set) var lastError: String?

    init() {
        Self.active = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), pasteoryHotKeyHandler, 1, &eventType, nil, &handlerReference)
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        let signature = OSType(0x50535445)
        var newReference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &newReference)
        if status == noErr {
            reference = newReference; lastError = nil; return true
        }
        lastError = "快捷键已被其他应用占用（错误码 \(status)）"
        return false
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        lastError = nil
    }

    fileprivate func fire() { onPress?() }
}

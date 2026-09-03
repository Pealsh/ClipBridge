import Foundation
import Carbon.HIToolbox
import AppKit

/// システム全体のホットキー登録。
///
/// Carbon の `RegisterEventHotKey` を使う。CGEventTap と違って
/// **アクセシビリティ権限が不要**なのが利点。
/// ただし登録したキーは他アプリに届かなくなる（Option+V なら「√」が打てなくなる）。
final class HotKeyManager {

    typealias Handler = () -> Void

    enum Slot: UInt32 { case send = 1, pause = 2 }

    private static let signature: OSType = 0x43_42_52_47   // 'CBRG'

    private var handlers: [UInt32: Handler] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    /// 登録に失敗したホットキー（他アプリが先に取っている等）
    private(set) var failures: [String] = []

    init() { installEventHandler() }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: - 登録

    /// 設定に従ってホットキーを登録し直す
    func apply(config: HotKeyConfig, onSend: @escaping Handler, onPause: @escaping Handler) {
        unregisterAll()
        failures.removeAll()

        register(slot: .send,
                 keyCode: config.sendKeyCode,
                 modifiers: config.sendModifiers,
                 label: config.sendDescription,
                 handler: onSend)

        register(slot: .pause,
                 keyCode: config.pauseKeyCode,
                 modifiers: config.pauseModifiers,
                 label: config.pauseDescription,
                 handler: onPause)
    }

    private func register(slot: Slot, keyCode: UInt32, modifiers: UInt32,
                          label: String, handler: @escaping Handler) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[slot.rawValue] = ref
            handlers[slot.rawValue] = handler
        } else {
            Log.error("ホットキー登録失敗:", label, "status=\(status)")
            failures.append(label)
        }
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    // MARK: - イベント配線

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(eventRef,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            guard err == noErr, hkID.signature == HotKeyManager.signature else { return noErr }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.fire(id: hkID.id)
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                            callback,
                            1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
    }

    private func fire(id: UInt32) {
        guard let handler = handlers[id] else { return }
        DispatchQueue.main.async(execute: handler)
    }
}

import AppKit
import Carbon

/// Global hotkeys through Carbon's RegisterEventHotKey, the same API Raycast uses.
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var installed = false
    private(set) static var status = ""

    private static var mainHandler: (() -> Void)?
    static let defaults = [
        HotkeyBinding(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "⌘Space"),
        HotkeyBinding(keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue, label: "⌥Space")
    ]
    static func bindings(in store: UserDefaults = .standard) -> [HotkeyBinding?] {
        guard let data = store.data(forKey: "launcherHotkeys"),
              let saved = try? JSONDecoder().decode([HotkeyBinding?].self, from: data),
              saved.count == 2 else { return defaults.map { Optional($0) } }
        return saved
    }

    static func registerMain(_ handler: @escaping () -> Void) {
        mainHandler = handler
        refreshMain()
    }

    private static func refreshMain() {
        unregister(1)
        unregister(2)
        status = bindings().enumerated().map { index, binding in
            guard let binding else { return "Shortcut \(index + 1) off" }
            let ok = register(id: UInt32(index + 1), keyCode: binding.keyCode,
                              modifiers: NSEvent.ModifierFlags(rawValue: binding.modifiers)) { mainHandler?() }
            return binding.label + (ok ? " active" : " taken")
        }.joined(separator: ", ")
        NotificationCenter.default.post(name: .init("LumenHotkeysChanged"), object: nil)
    }

    /// Try the new shortcut before replacing the saved one, so a conflict keeps the old binding.
    static func setMain(_ binding: HotkeyBinding?, at index: Int) -> String? {
        guard (0..<2).contains(index) else { return "Unknown shortcut." }
        var saved = bindings()
        if let binding {
            if let current = saved[index], current.keyCode == binding.keyCode,
               current.modifiers == binding.modifiers { return nil }
            guard register(id: 3, keyCode: binding.keyCode,
                           modifiers: NSEvent.ModifierFlags(rawValue: binding.modifiers), {}) else {
                return "That shortcut is already in use. Choose another or disable it in the other app."
            }
            unregister(3)
        }
        saved[index] = binding
        guard let data = try? JSONEncoder().encode(saved) else { return "Could not save shortcut." }
        UserDefaults.standard.set(data, forKey: "launcherHotkeys")
        refreshMain()
        return nil
    }

    @discardableResult
    static func register(id: UInt32, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, _ handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        unregister(id)
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C_55_4D_4E), id: id)   // "LUMN"
        guard RegisterEventHotKey(UInt32(keyCode), carbon, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    static func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    /// Removes every hotkey with an ID at or above `first` (the per-command range).
    static func unregister(from first: UInt32) {
        for id in refs.keys where id >= first { unregister(id) }
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKeys.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}

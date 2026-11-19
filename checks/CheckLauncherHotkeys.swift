import Foundation

func checkLauncherHotkeys() {
    let launcher = Launcher()
    let ai = Item(id: "fixture.ai", title: "Ask AI", actions: [])
    let folder = Item(id: "fixture.folder", title: "agent-config", actions: [])
    launcher.applyReload([ai])
    launcher.applyReload([folder, ai])
    expect(launcher.selected?.id == folder.id, "async file result becomes default selection")
    launcher.chooseSelection(1)
    launcher.applyReload([folder, ai])
    expect(launcher.selected?.id == ai.id, "deliberately selected AI stays selected")
    launcher.chooseSelection(0)
    launcher.applyReload([ai, folder])
    expect(launcher.selected?.id == folder.id, "deliberate choice follows its identity")
    launcher.refresh()
    launcher.applyReload([ai])
    launcher.applyReload([folder, ai])
    expect(launcher.selected?.id == folder.id, "new search resets deliberate selection")

    let name = "Lumen.Hotkeys.Check." + UUID().uuidString
    let store = UserDefaults(suiteName: name)!
    defer { store.removePersistentDomain(forName: name) }
    expect(HotKeys.bindings(in: store).compactMap { $0 }.count == 2, "existing users keep both defaults")
    let saved: [HotkeyBinding?] = [HotKeys.defaults[0], nil]
    store.set(try! JSONEncoder().encode(saved), forKey: "launcherHotkeys")
    expect(HotKeys.bindings(in: store)[1] == nil, "removed Option-Space stays removed after reload")
    store.set(try! JSONEncoder().encode([HotkeyBinding?](repeating: nil, count: 2)), forKey: "launcherHotkeys")
    expect(HotKeys.bindings(in: store).allSatisfy { $0 == nil }, "both shortcuts may be disabled")
    store.set(Data("invalid".utf8), forKey: "launcherHotkeys")
    expect(HotKeys.bindings(in: store)[0]?.keyCode == 49, "invalid preferences recover defaults")
}

import AppKit

func checkSystem() {
    // Volume keys: 16 steps, from between two steps to the next one in that direction.
    expect(System.steppedVolume(0.5, up: true) == 0.5625, "volume up from 50%")
    expect(System.steppedVolume(0.5, up: false) == 0.4375, "volume down from 50%")
    expect(System.steppedVolume(0.3, up: true) == 0.3125, "volume up from between steps")
    expect(System.steppedVolume(0.3, up: false) == 0.25, "volume down from between steps")
    expect(System.steppedVolume(0.5000001, up: true) == 0.5625, "volume up ignores float noise")
    expect(System.steppedVolume(1, up: true) == 1, "volume up stops at 100%")
    expect(System.steppedVolume(0, up: false) == 0, "volume down stops at 0%")
    expect(System.percent(0.5625) == "56%" && System.percent(1) == "100%", "volume percent")

    // Media key events carry NX_KEYTYPE in the high word and 0xa00 / 0xb00 for down / up.
    expect(System.mediaKeyData(16, down: true) == 0x10_0a00, "play key down")
    expect(System.mediaKeyData(17, down: false) == 0x11_0b00, "next key up")

    // Eject only removable media, disk images and network shares under /Volumes, never the startup disk.
    expect(!System.canEject(path: "/", root: true, ejectable: false, removable: false, local: true), "startup disk stays")
    expect(!System.canEject(path: "/Volumes/Data2", root: false, ejectable: false, removable: false, local: true), "internal volume stays")
    expect(System.canEject(path: "/Volumes/Stick", root: false, ejectable: true, removable: false, local: true), "ejectable volume goes")
    expect(System.canEject(path: "/Volumes/Card", root: false, ejectable: false, removable: true, local: true), "removable volume goes")
    expect(System.canEject(path: "/Volumes/share", root: false, ejectable: false, removable: false, local: false), "network share goes")
    expect(!System.canEject(path: "/Users/someone/VirtualDisk", root: false, ejectable: false, removable: false, local: false), "mounts outside /Volumes stay")

    // Wi-Fi device from networksetup.
    let ports = """
    Hardware Port: Ethernet Adapter (en4)
    Device: en4
    Ethernet Address: 9e:7e:a0:68:c1:41

    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: 60:3e:5f:7b:84:52

    Hardware Port: Thunderbolt Bridge
    Device: bridge0
    """
    expect(System.wifiDevice(ports) == "en0", "wifi device")
    expect(System.wifiDevice("Hardware Port: AirPort\nDevice: en1\n") == "en1", "old AirPort name")
    expect(System.wifiDevice("Hardware Port: Ethernet\nDevice: en4\n") == nil, "no wifi port")

    // Show Desktop: F11 with fn unless customized in System Settings.
    let fn = CGEventFlags.maskSecondaryFn
    expect(System.showDesktopKey(nil)?.code == 103 && System.showDesktopKey([:])?.flags == fn, "show desktop default is fn+F11")
    let custom: [String: Any] = ["36": ["enabled": true, "value": ["parameters": [65535, 2, 1_572_864], "type": "standard"]]]
    expect(System.showDesktopKey(custom)?.code == 2 && System.showDesktopKey(custom)?.flags.rawValue == 1_572_864, "show desktop custom key")
    let off: [String: Any] = ["36": ["enabled": false, "value": ["parameters": [65535, 103, 8_388_608], "type": "standard"]]]
    expect(System.showDesktopKey(off) == nil, "show desktop switched off")
    let unbound: [String: Any] = ["36": ["enabled": true, "value": ["parameters": [65535, 65535, 0], "type": "standard"]]]
    expect(System.showDesktopKey(unbound) == nil, "show desktop without a key")
    let negative: [String: Any] = ["36": ["enabled": true, "value": ["parameters": [65535, 2, -1], "type": "standard"]]]
    expect(System.showDesktopKey(negative) == nil, "a negative modifier value is unusable, not a trap")

    // Notification Center actions: "Clear All" beats "Close"; everything else is left alone.
    let close = "Name:Close\nTarget:0x0\nSelector:(null)", clearAll = "Name:Clear All\nTarget:0x0\nSelector:(null)"
    expect(System.actionName(close) == "Close", "action name")
    expect(System.dismissAction([close]) == close, "close a banner")
    expect(System.dismissAction([close, clearAll]) == clearAll, "clear all beats close")
    expect(System.dismissAction(["AXPress", "Name:Show\nTarget:0x0\nSelector:(null)", "Name:Options\nTarget:0x0\nSelector:(null)"]) == nil,
           "other actions are not dismissals")

    // Audio device lists answer without crashing, and each device is a real input or output.
    for input in [false, true] {
        let devices = SystemAudio.devices(input: input)
        expect(Set(devices.map(\.uid)).count == devices.count, "device uids are unique")
        expect(devices.allSatisfy { !$0.name.isEmpty }, "devices have names")
    }

    // Item ids stay unique and prefixed, so ranking, favorites and hotkeys keep working.
    let ids = System.commands().map(\.id)
    expect(Set(ids).count == ids.count, "system command ids are unique")
    expect(ids.allSatisfy { $0.hasPrefix("sys.") }, "system command ids are prefixed")
    for id in ["sys.lock", "sys.sleep", "sys.restart", "sys.shutdown", "sys.logout", "sys.trash", "sys.dark"] {
        expect(ids.contains(id), "existing command \(id) is kept")
    }
}

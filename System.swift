import AppKit
import CoreAudio

/// System Actions: power, apps, displays, disks, sound, media keys, Wi-Fi, notifications.
/// Commands on "the active app" use the frontmost application, which is the one the user came from
/// because the launcher panel does not activate Lumen.
enum System {
    static func commands() -> [Item] {
        power() + apps() + desktop() + sound() + media() + network()
    }

    private static func power() -> [Item] {
        [
            .command("sys.lock", "Lock Screen", kind: "System", icon: "lock", keywords: ["sperren"]) {
                later { AX.key(12, [.maskCommand, .maskControl]) }
            },
            .command("sys.sleep", "Sleep", kind: "System", icon: "moon.zzz", keywords: ["ruhezustand"]) {
                shell("/usr/bin/pmset", "sleepnow")
            },
            .command("sys.restart", "Restart", kind: "System", icon: "arrow.clockwise", keywords: ["reboot", "neustart"]) {
                if confirm("Restart your Mac now?") { osascript("tell application \"System Events\" to restart") }
            },
            .command("sys.shutdown", "Shut Down", kind: "System", icon: "power", keywords: ["power off", "ausschalten"]) {
                if confirm("Shut down your Mac now?") { osascript("tell application \"System Events\" to shut down") }
            },
            .command("sys.logout", "Log Out", kind: "System", icon: "rectangle.portrait.and.arrow.right", keywords: ["abmelden"]) {
                if confirm("Log out now?") { osascript("tell application \"System Events\" to log out") }
            },
            .command("sys.trash", "Empty Trash", kind: "System", icon: "trash", keywords: ["papierkorb"]) {
                if confirm("Empty the Trash? This cannot be undone.") { osascript("tell application \"Finder\" to empty trash") }
            },
            .command("sys.dark", "Toggle Dark Mode", kind: "System", icon: "circle.lefthalf.filled",
                     keywords: ["appearance", "light mode", "dunkelmodus"]) {
                osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            },
            .command("sys.screensaver", "Start Screen Saver", kind: "System", icon: "tv", keywords: ["bildschirmschoner"]) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                                                   configuration: NSWorkspace.OpenConfiguration())
            },
            .command("sys.display-sleep", "Sleep Displays", kind: "System", icon: "display",
                     keywords: ["monitor off", "bildschirm aus", "display aus"]) {
                shell("/usr/bin/pmset", "displaysleepnow")
            },
        ]
    }

    // MARK: Apps

    /// The app the user came from. Never Lumen: its alerts and Settings window can take focus.
    private static func frontApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
    }

    private static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private static func apps() -> [Item] {
        [
            .command("sys.quit-all", "Quit All Apps", kind: "System", icon: "xmark.rectangle",
                     keywords: ["close all", "alle apps beenden", "beenden"]) { quitApps(except: false) },
            .command("sys.quit-others", "Quit All Apps Except Frontmost", kind: "System", icon: "xmark.rectangle",
                     keywords: ["quit others", "andere apps beenden", "beenden"]) { quitApps(except: true) },
            .command("sys.quit-active", "Quit the Active App", kind: "System", icon: "xmark.circle",
                     keywords: ["close app", "app beenden", "beenden"]) { quitActive() },
            .command("sys.restart-app", "Restart Frontmost App", kind: "System", icon: "arrow.counterclockwise",
                     keywords: ["relaunch", "app neu starten", "neustart"]) { restartActive() },
            .command("sys.hide-others", "Hide All Apps Except Frontmost", kind: "System", icon: "eye.slash",
                     keywords: ["hide others", "ausblenden", "andere ausblenden"]) { hideOthers() },
            .command("sys.unhide-all", "Unhide All Hidden Apps", kind: "System", icon: "eye",
                     keywords: ["show all apps", "einblenden", "alle einblenden"]) { unhideAll() },
        ]
    }

    /// Quits every regular app except Lumen and Finder (and the frontmost one with `keepFront`) after asking.
    private static func quitApps(except keepFront: Bool) {
        let front = frontApp()   // before the alert: it activates Lumen
        if keepFront, front == nil { return HUD.show("No Active App") }
        let victims = regularApps().filter {
            $0.bundleIdentifier != "com.apple.finder" && !(keepFront && $0.processIdentifier == front?.processIdentifier)
        }
        guard !victims.isEmpty else { return HUD.show("No Apps to Quit") }
        let stays = keepFront ? "Finder and " + (front?.localizedName ?? "the active app") : "Finder"
        guard confirm("Quit \(count(victims.count, "app"))? \(stays) stay open.") else { return }
        victims.forEach { $0.terminate() }
        HUD.show("Quitting " + count(victims.count, "App"))
    }

    private static func quitActive() {
        guard let app = frontApp() else { return HUD.show("No Active App") }
        let name = app.localizedName ?? "App"
        HUD.show(app.terminate() ? "Quitting " + name : "Could not quit " + name)
    }

    private static func restartActive() {
        guard let app = frontApp(), let url = app.bundleURL else { return HUD.show("No Active App") }
        let name = app.localizedName ?? "App"
        guard app.terminate() else { return HUD.show("Could not quit " + name) }
        var tries = 0
        func relaunch() {
            if app.isTerminated {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                HUD.show("Restarting " + name)
            } else if tries >= 40 {   // 10 s: a save dialog is probably waiting
                HUD.show(name + " did not quit")
            } else {
                tries += 1
                later(0.25, relaunch)
            }
        }
        relaunch()
    }

    private static func hideOthers() {
        guard let front = frontApp() else { return HUD.show("No Active App") }
        let others = regularApps().filter { $0.processIdentifier != front.processIdentifier && !$0.isHidden }
        others.forEach { $0.hide() }
        HUD.show(others.isEmpty ? "No Other Apps Visible" : "Hid " + count(others.count, "App"))
    }

    private static func unhideAll() {
        let hidden = regularApps().filter(\.isHidden)
        hidden.forEach { $0.unhide() }
        HUD.show(hidden.isEmpty ? "No Hidden Apps" : "Unhid " + count(hidden.count, "App"))
    }

    // MARK: Desktop, disks, Finder, notifications

    private static func desktop() -> [Item] {
        [
            .command("sys.show-desktop", "Show Desktop", kind: "System", icon: "desktopcomputer",
                     keywords: ["desktop anzeigen", "schreibtisch", "hide windows"]) { showDesktop() },
            .command("sys.eject-all", "Eject All Disks", kind: "System", icon: "eject",
                     keywords: ["unmount", "auswerfen", "laufwerke", "volumes"]) { ejectAll() },
            .command("sys.hidden-files", "Toggle Hidden Files", kind: "System", icon: "eye.square",
                     keywords: ["finder", "show hidden files", "versteckte dateien", "dotfiles"]) {
                let show = !flag("com.apple.finder", "AppleShowAllFiles")
                setFlag("com.apple.finder", "AppleShowAllFiles", show)
                shell("/usr/bin/killall", "Finder")   // Finder restarts by itself and reads the new value
                HUD.show(show ? "Hidden Files Shown" : "Hidden Files Hidden")
            },
            .command("sys.stage-manager", "Toggle Stage Manager", kind: "System", icon: "rectangle.3.group",
                     keywords: ["window manager", "stage", "fensterorganisation"]) {
                let on = !flag("com.apple.WindowManager", "GloballyEnabled")
                setFlag("com.apple.WindowManager", "GloballyEnabled", on)
                HUD.show(on ? "Stage Manager On" : "Stage Manager Off")
            },
            .command("sys.dismiss-notifications", "Dismiss Notifications", kind: "System", icon: "bell.slash",
                     keywords: ["clear notifications", "mitteilungen", "benachrichtigungen", "banners"]) { dismissNotifications() },
        ]
    }

    private static func flag(_ domain: String, _ key: String) -> Bool {
        CFPreferencesGetAppBooleanValue(key as CFString, domain as CFString, nil)
    }

    private static func setFlag(_ domain: String, _ key: String, _ value: Bool) {
        CFPreferencesSetAppValue(key as CFString, value ? kCFBooleanTrue : kCFBooleanFalse, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    /// The key behind System Settings → Keyboard Shortcuts → Mission Control → Show Desktop (symbolic hotkey 36).
    /// Not customized means F11 with fn; nil when the user switched it off or the entry is unusable.
    static func showDesktopKey(_ hotkeys: [String: Any]?) -> (code: CGKeyCode, flags: CGEventFlags)? {
        guard let entry = hotkeys?["36"] as? [String: Any] else { return (103, .maskSecondaryFn) }
        guard (entry["enabled"] as? NSNumber)?.boolValue == true,
              let p = (entry["value"] as? [String: Any])?["parameters"] as? [Int], p.count >= 3, (0..<0xFFFF).contains(p[1]),
              let flags = UInt64(exactly: p[2])   // a negative value in the preferences must not trap
        else { return nil }
        return (CGKeyCode(p[1]), CGEventFlags(rawValue: flags))
    }

    private static func showDesktop() {
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        guard let key = showDesktopKey(hotkeys as? [String: Any]) else {
            return HUD.show("Turn on Show Desktop in Keyboard Shortcuts")
        }
        later { AX.key(key.code, key.flags) }
    }

    /// Volumes worth ejecting: removable media, disk images and network shares mounted under /Volumes (not
    /// OrbStack-style mounts elsewhere), never the startup disk.
    static func canEject(path: String, root: Bool, ejectable: Bool, removable: Bool, local: Bool) -> Bool {
        path.hasPrefix("/Volumes/") && !root && (ejectable || removable || !local)
    }

    private static func ejectAll() {
        let keys: Set<URLResourceKey> = [.volumeIsRootFileSystemKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey]
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .filter { url in
                let v = try? url.resourceValues(forKeys: keys)
                return canEject(path: url.path, root: v?.volumeIsRootFileSystem ?? true, ejectable: v?.volumeIsEjectable ?? false,
                                removable: v?.volumeIsRemovable ?? false, local: v?.volumeIsLocal ?? true)
            }
        guard !volumes.isEmpty else { return HUD.show("No Disks to Eject") }
        DispatchQueue.global().async {   // unmounting can take a while
            var failed: [String] = []
            for url in volumes {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { failed.append(url.lastPathComponent) }
            }
            DispatchQueue.main.async {
                let done = volumes.count - failed.count
                HUD.show(failed.isEmpty ? "Ejected " + count(done, "Disk")
                         : (done > 0 ? "Ejected \(done), " : "") + "could not eject " + failed.joined(separator: ", "))
            }
        }
    }

    /// Best effort: Notification Center exposes a "Close" action on every banner and a "Clear All" action on every
    /// stack (macOS 26: an AXNotificationCenterBanner group), found by walking the windows of its Accessibility tree
    /// because the layout changes between macOS versions.
    private static func dismissNotifications() {
        guard AX.promptIfNeeded() else { return }
        DispatchQueue.global().async {
            let n = dismissAllNotifications()
            DispatchQueue.main.async {
                HUD.show(n == nil ? "Notification Center Is Not Running" : n! > 0 ? "Notifications Dismissed" : "No Notifications Found")
            }
        }
    }

    /// Dismisses everything Notification Center shows and returns how many actions succeeded; nil when it is not running.
    static func dismissAllNotifications() -> Int? {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return nil }
        let app = AXUIElementCreateApplication(nc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        var dismissed = 0
        for _ in 0..<3 {   // clearing a stack can reveal the banners below it
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            let found = (windows as? [AXUIElement] ?? []).flatMap { dismissActions($0) }
            for (element, action) in found where AXUIElementPerformAction(element, action as CFString) == .success { dismissed += 1 }
            if found.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return dismissed
    }

    private static func dismissActions(_ element: AXUIElement, depth: Int = 0) -> [(AXUIElement, String)] {
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let action = dismissAction(names as? [String] ?? []) {
            return [(element, action)]   // a stack's "Clear All" covers the banners inside it
        }
        var children: CFTypeRef?
        guard depth < 10, AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return [] }
        return kids.flatMap { dismissActions($0, depth: depth + 1) }
    }

    /// Accessibility lists custom actions as "Name:Close\nTarget:0x0\nSelector:(null)".
    static func actionName(_ raw: String) -> String {
        guard raw.hasPrefix("Name:") else { return raw }
        return String(raw.dropFirst(5).prefix { $0 != "\n" })
    }

    /// The action that dismisses a notification or stack (German names from memory), "Clear All" before "Close".
    static func dismissAction(_ actions: [String]) -> String? {
        let clearAll: Set = ["clear all", "alle entfernen"], close: Set = ["close", "clear", "schließen", "entfernen"]
        let lowered = actions.map { (raw: $0, name: actionName($0).lowercased()) }
        return (lowered.first { clearAll.contains($0.name) } ?? lowered.first { close.contains($0.name) })?.raw
    }

    // MARK: Sound

    private static func sound() -> [Item] {
        let kw = ["lautstärke", "sound", "audio", "ton"]
        var items: [Item] = [
            .command("sys.mute", "Toggle Mute", kind: "System", icon: "speaker.slash", keywords: kw + ["stumm", "stummschalten", "unmute"]) {
                guard let muted = SystemAudio.isMuted(), SystemAudio.setMuted(!muted) else { return HUD.show("This Output Cannot Be Muted") }
                HUD.show(muted ? "Unmuted" : "Muted")
            },
            .command("sys.volume-up", "Turn Volume Up", kind: "System", icon: "speaker.plus", keywords: kw + ["lauter", "louder"]) { stepVolume(up: true) },
            .command("sys.volume-down", "Turn Volume Down", kind: "System", icon: "speaker.minus", keywords: kw + ["leiser", "quieter"]) { stepVolume(up: false) },
            .command("sys.mic-mute", "Toggle Microphone Mute", kind: "System", icon: "mic.slash",
                     keywords: ["mikrofon", "stumm", "input", "audio", "microphone"]) { toggleMicrophone() },
            .command("sys.sound-out", "Manage Sound Output Devices", kind: "System", icon: "speaker.wave.2",
                     keywords: ["audio", "speaker", "lautsprecher", "kopfhörer", "headphones", "ausgabe", "output"], closes: false) {
                pushDevices(input: false)
            },
            .command("sys.sound-in", "Manage Sound Input Devices", kind: "System", icon: "mic",
                     keywords: ["audio", "microphone", "mikrofon", "eingabe", "input"], closes: false) {
                pushDevices(input: true)
            },
        ]
        for (percent, symbol) in [(0, "speaker"), (25, "speaker.wave.1"), (50, "speaker.wave.2"), (75, "speaker.wave.2"), (100, "speaker.wave.3")] {
            items.append(.command("sys.volume-\(percent)", "Set Volume to \(percent)%", kind: "System", icon: symbol,
                                  keywords: kw + ["volume \(percent)", "lautstärke \(percent)"]) { setVolume(Float(percent) / 100) })
        }
        return items
    }

    /// The volume keys move in 16 steps (6.25% each); from between two steps they go to the next one in that direction.
    static func steppedVolume(_ v: Float, up: Bool) -> Float {
        let steps = v * 16
        return min(max(up ? (steps + 0.001).rounded(.down) + 1 : (steps - 0.001).rounded(.up) - 1, 0), 16) / 16
    }

    static func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

    private static func setVolume(_ v: Float) {
        guard SystemAudio.setVolume(v) else { return HUD.show("This Output Has No Volume Control") }
        if v > 0 { _ = SystemAudio.setMuted(false) }   // like the volume keys
        HUD.show("Volume " + percent(v))
    }

    private static func stepVolume(up: Bool) {
        guard let v = SystemAudio.volume() else { return HUD.show("This Output Has No Volume Control") }
        setVolume(steppedVolume(v, up: up))
    }

    /// Mutes through the device's mute switch (checked by reading it back), or through input volume 0 when that fails.
    private static var micVolumeBeforeMute: Float?

    private static func toggleMicrophone() {
        if let muted = SystemAudio.isMuted(input: true), SystemAudio.setMuted(!muted, input: true), SystemAudio.isMuted(input: true) == !muted {
            return HUD.show(muted ? "Microphone On" : "Microphone Muted")
        }
        guard let v = SystemAudio.volume(input: true) else { return HUD.show("This Microphone Cannot Be Muted") }
        if v > 0 { micVolumeBeforeMute = v }
        let target = v > 0 ? 0 : micVolumeBeforeMute ?? 0.75
        HUD.show(SystemAudio.setVolume(target, input: true) ? (v > 0 ? "Microphone Muted" : "Microphone On") : "Could Not Change the Microphone")
    }

    private static func pushDevices(input: Bool) {
        let kind = input ? "Input" : "Output"
        Launcher.shared.push(.list(ListSpec(title: "Sound \(kind) Devices", placeholder: "Search devices…") { deviceItems(input: input, matching: $0) }))
    }

    private static func deviceItems(input: Bool, matching q: String) -> [Item] {
        let current = SystemAudio.defaultDevice(input: input)
        let kind = input ? "Input" : "Output"
        let found = SystemAudio.devices(input: input).filter { q.isEmpty || matchScore(q, $0.name) > 0 }
        guard !found.isEmpty else {
            return [Item(id: "sys.no-device", title: q.isEmpty ? "No \(kind.lowercased()) devices" : "No matching devices",
                         icon: .symbol(input ? "mic" : "speaker.wave.2"), track: false, actions: [])]
        }
        return found.map { d in
            let transport = SystemAudio.transport(d.transport)
            return Item(id: "sys.\(input ? "in" : "out").\(d.uid)", title: d.name, subtitle: d.id == current ? "Current" : "",
                 kind: transport.label, icon: .symbol(d.id == current ? "checkmark.circle.fill" : transport.symbol(input)), track: false,
                 actions: [Action(title: "Use as \(kind) Device", icon: input ? "mic" : "speaker.wave.2") {
                     HUD.show(SystemAudio.setDefault(d, input: input) ? "\(kind): \(d.name)" : "Could Not Switch to \(d.name)")
                 }])
        }
    }

    // MARK: Media keys, Wi-Fi

    private static func media() -> [Item] {
        [
            .command("sys.play-pause", "Play / Pause", kind: "System", icon: "playpause",
                     keywords: ["music", "musik", "wiedergabe", "pause", "play"]) { mediaKey(16, "Play / Pause") },
            .command("sys.next-track", "Next Track", kind: "System", icon: "forward",
                     keywords: ["skip", "nächster titel", "weiter", "next song"]) { mediaKey(17, "Next Track") },
            .command("sys.previous-track", "Previous Track", kind: "System", icon: "backward",
                     keywords: ["vorheriger titel", "zurück", "back", "previous song"]) { mediaKey(18, "Previous Track") },
        ]
    }

    /// data1 of a media key event: NX_KEYTYPE in the high word, 0xa00 for key down, 0xb00 for key up.
    static func mediaKeyData(_ key: Int, down: Bool) -> Int { (key << 16) | (down ? 0xa00 : 0xb00) }

    private static func mediaKey(_ key: Int, _ label: String) {
        guard AX.promptIfNeeded() else { return }
        for down in [true, false] {
            let data = mediaKeyData(key, down: down)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(data & 0xffff)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        HUD.show(label)
    }

    private static func network() -> [Item] {
        [.command("sys.wifi", "Toggle Wi-Fi", kind: "System", icon: "wifi", keywords: ["wlan", "wifi", "network", "netzwerk", "internet"]) { toggleWiFi() }]
    }

    /// The device of the "Wi-Fi" hardware port in `networksetup -listallhardwareports` output.
    static func wifiDevice(_ listing: String) -> String? {
        var inWiFi = false
        for line in listing.split(separator: "\n") {
            if let port = line.range(of: "Hardware Port:").map({ line[$0.upperBound...].trimmingCharacters(in: .whitespaces) }) {
                inWiFi = port == "Wi-Fi" || port == "AirPort"
            } else if inWiFi, let device = line.range(of: "Device:").map({ line[$0.upperBound...].trimmingCharacters(in: .whitespaces) }) {
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }

    private static func output(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private static func toggleWiFi() {
        DispatchQueue.global().async {
            let networksetup = "/usr/sbin/networksetup"
            var message = "Wi-Fi Not Found"
            if let ports = output(networksetup, ["-listallhardwareports"]), let device = wifiDevice(ports),
               let power = output(networksetup, ["-getairportpower", device]) {
                let on = !power.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("On")
                message = output(networksetup, ["-setairportpower", device, on ? "on" : "off"]) != nil
                    ? (on ? "Wi-Fi On" : "Wi-Fi Off") : "Could Not Switch Wi-Fi"
            }
            DispatchQueue.main.async { HUD.show(message) }
        }
    }

    static func lumenCommands() -> [Item] {
        [
            .command("lumen.settings", "Lumen Settings", kind: "Lumen", icon: "gearshape", keywords: ["preferences", "einstellungen"]) {
                Settings.show()
            },
            .command("lumen.quit", "Quit Lumen", kind: "Lumen", icon: "xmark.circle") { NSApp.terminate(nil) },
        ]
    }
}

/// CoreAudio: default devices, volume and mute. Volume and mute live on the main element or, for devices
/// without one, on each of the first two channels.
enum SystemAudio {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663   // 'vmvc'

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func get<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ empty: T) -> T? {
        var a = address, value = empty, size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? value : nil
    }

    private static func set<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = address, v = value
        return withUnsafeBytes(of: &v) { AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0.baseAddress!) } == noErr
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        get(id, address(selector), Unmanaged<CFString>?.none).flatMap { $0?.takeRetainedValue() as String? }
    }

    private static func canSet(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address, settable = DarwinBoolean(false)
        return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }

    // MARK: Devices

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        return get(system, address(selector), AudioDeviceID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    /// Sets the default device; for output also the one used for alerts and sound effects, like System Settings does.
    static func setDefault(_ d: Device, input: Bool) -> Bool {
        if !input { _ = set(system, address(kAudioHardwarePropertyDefaultSystemOutputDevice), d.id) }
        return set(system, address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), d.id)
    }

    /// Visible devices with at least one input or output channel, sorted by name.
    static func devices(input: Bool) -> [Device] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id -> Device? in
            guard channels(id, input: input) > 0, get(id, address(kAudioDevicePropertyIsHidden), UInt32(0)) != 1,
                  let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, uid: uid, name: name,
                          transport: get(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, buffer) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transport(_ code: UInt32) -> (label: String, symbol: (_ input: Bool) -> String) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return ("Built-in", { $0 ? "mic" : "speaker.wave.2" })
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return ("Bluetooth", { $0 ? "mic" : "headphones" })
        case kAudioDeviceTransportTypeUSB: return ("USB", { $0 ? "mic" : "speaker.wave.2" })
        case kAudioDeviceTransportTypeHDMI: return ("HDMI", { _ in "display" })
        case kAudioDeviceTransportTypeDisplayPort: return ("DisplayPort", { _ in "display" })
        case kAudioDeviceTransportTypeAirPlay: return ("AirPlay", { _ in "airplayaudio" })
        case kAudioDeviceTransportTypeThunderbolt: return ("Thunderbolt", { $0 ? "mic" : "speaker.wave.2" })
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return ("Virtual", { _ in "waveform" })
        default: return ("", { $0 ? "mic" : "speaker.wave.2" })
        }
    }

    // MARK: Volume and mute of the default device

    private static func writable(_ device: AudioDeviceID, _ selectors: [AudioObjectPropertySelector], input: Bool) -> [AudioObjectPropertyAddress] {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        for selector in selectors {
            let main = address(selector, scope)
            if canSet(device, main) { return [main] }
            let channels = [1, 2].map { address(selector, scope, $0) }.filter { canSet(device, $0) }
            if !channels.isEmpty { return channels }
        }
        return []
    }

    private static func volumeAddresses(_ device: AudioDeviceID, input: Bool) -> [AudioObjectPropertyAddress] {
        writable(device, input ? [kAudioDevicePropertyVolumeScalar] : [virtualMainVolume, kAudioDevicePropertyVolumeScalar], input: input)
    }

    static func volume(input: Bool = false) -> Float? {
        guard let device = defaultDevice(input: input), let a = volumeAddresses(device, input: input).first else { return nil }
        return get(device, a, Float(0))
    }

    static func setVolume(_ v: Float, input: Bool = false) -> Bool {
        guard let device = defaultDevice(input: input) else { return false }
        let addresses = volumeAddresses(device, input: input)
        return !addresses.isEmpty && addresses.map { set(device, $0, v) }.allSatisfy { $0 }
    }

    static func isMuted(input: Bool = false) -> Bool? {
        guard let device = defaultDevice(input: input), let a = writable(device, [kAudioDevicePropertyMute], input: input).first else { return nil }
        return get(device, a, UInt32(0)).map { $0 != 0 }
    }

    static func setMuted(_ muted: Bool, input: Bool = false) -> Bool {
        guard let device = defaultDevice(input: input) else { return false }
        let addresses = writable(device, [kAudioDevicePropertyMute], input: input)
        return !addresses.isEmpty && addresses.map { set(device, $0, UInt32(muted ? 1 : 0)) }.allSatisfy { $0 }
    }
}

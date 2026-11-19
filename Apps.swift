import AppKit

enum Apps {
    private struct Entry {
        let path: String
        let name: String
        let file: String
        let localized: [String]
        let icon: NSImage
    }

    private static var entries: [Entry] = []
    private static var loaded = Date.distantPast

    /// Rescans the application folders in the background once a minute; searches use the last scan meanwhile.
    private static func reloadIfStale() {
        guard Date().timeIntervalSince(loaded) > 60 else { return }
        loaded = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = scan()
            DispatchQueue.main.async {
                entries = fresh
                Launcher.shared.reload()
            }
        }
    }

    /// The usual application folders, one level deep into subfolders such as /Applications/Setapp.
    private static func scan() -> [Entry] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", "/System/Library/CoreServices/Applications",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var paths: Set<String> = ["/System/Library/CoreServices/Finder.app"]
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
                let path = root + "/" + name
                if name.hasSuffix(".app") { paths.insert(path); continue }
                for sub in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where sub.hasSuffix(".app") {
                    paths.insert(path + "/" + sub)
                }
            }
        }
        return paths.sorted().map { path in
            Entry(path: path, name: fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                  file: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                  localized: localizedNames(path), icon: NSWorkspace.shared.icon(forFile: path))
        }
    }

    /// Display names in the user's preferred languages, so "Schlüsselbundverwaltung" finds Keychain Access on an English system.
    /// Read straight from the bundle (InfoPlist.loctable or <lang>.lproj/InfoPlist.strings); soft hyphens are dropped.
    private static func localizedNames(_ path: String) -> [String] {
        let resources = path + "/Contents/Resources"
        let table = NSDictionary(contentsOfFile: resources + "/InfoPlist.loctable") as? [String: [String: Any]]
        var names: [String] = []
        for tag in Locale.preferredLanguages {
            let lang = tag.replacingOccurrences(of: "-", with: "_")
            for key in [lang, lang.components(separatedBy: "_")[0]] {
                let info = table?[key] ?? NSDictionary(contentsOfFile: "\(resources)/\(key).lproj/InfoPlist.strings") as? [String: Any]
                names += ["CFBundleDisplayName", "CFBundleName"].compactMap { info?[$0] as? String }
            }
        }
        return names.map { $0.replacingOccurrences(of: "\u{AD}", with: "") }
    }

    static func items() -> [Item] {
        reloadIfStale()
        let running = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in app.bundleURL.map { ($0.path, app) } },
                                 uniquingKeysWith: { first, _ in first })
        return entries.map { item($0, running: running[$0.path]) }
    }

    private static func item(_ e: Entry, running app: NSRunningApplication?) -> Item {
        let url = URL(fileURLWithPath: e.path)
        var actions = [
            Action(title: "Open Application", icon: "arrow.up.forward.app") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) },
            Action(title: "Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
        ]
        if let app {
            actions += [
                Action(title: "Quit Application", icon: "xmark.circle", shortcut: Shortcut(.command, "q")) { app.terminate() },
                Action(title: "Force Quit Application", icon: "bolt.circle", shortcut: Shortcut([.command, .option], "q"),
                       destructive: true) {
                    if confirm("Force quit \(e.name)? Unsaved changes are lost.") { app.forceTerminate() }
                },
                Action(title: app.isHidden ? "Unhide Application" : "Hide Application", icon: "eye.slash",
                       shortcut: Shortcut(.command, "h")) { _ = app.isHidden ? app.unhide() : app.hide() },
            ]
        }
        actions += [
            Action(title: "Show Info in Finder", icon: "info.circle", shortcut: Shortcut(.command, "i")) {
                osascript("tell application \"Finder\"\nactivate\nopen information window of (POSIX file \(appleScriptString(e.path)) as alias)\nend tell")
            },
            .copy("Copy Name", shortcut: Shortcut([.command, .shift], "n")) { e.name },
            .copy("Copy Path", shortcut: Shortcut([.command, .shift], "p")) { e.path },
            .copy("Copy Bundle Identifier", shortcut: Shortcut([.command, .shift], "b")) { Bundle(url: url)?.bundleIdentifier ?? "" },
        ]
        return Item(id: e.path, title: e.name, kind: app == nil ? "Application" : "Running", icon: .image(e.icon),
                    keywords: Array(Set([e.file] + e.localized).subtracting([e.name])), actions: actions)
    }
}

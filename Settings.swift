import AppKit
import Contacts
import EventKit
import ServiceManagement
import SwiftUI

// Keep the property-wrapper spelling unambiguous: recent SDKs also export a
// State macro whose SwiftUIMacros plugin is absent from standalone Command Line Tools.
private typealias SettingsState<Value> = SwiftUI.State<Value>

enum Settings {
    private static var window: NSWindow?

    static func show() {
        PanelController.shared.hide()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Lumen Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        // A fixed size: a grouped Form has no height of its own, and the window would collapse to nothing.
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 460)
    }
}

private struct GeneralSettings: View {
    @SettingsState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @SettingsState private var refresh = 0   // re-reads permission states after a button press

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Lumen at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
            Section("Launcher Hotkeys") {
                LauncherHotkeyRow(index: 0)
                LauncherHotkeyRow(index: 1)
                Text("Changes apply immediately. Remove a shortcut to free it for another app. You can always open Lumen from the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                permission("Accessibility", granted: refresh >= 0 && AXIsProcessTrusted(),
                           detail: "Window commands, paste, selected text") {
                    _ = AX.promptIfNeeded()
                    open("Privacy_Accessibility")
                }
                permission("Screen Recording", granted: refresh >= 0 && CGPreflightScreenCaptureAccess(),
                           detail: "Send Window, Screen or Area to AI") {
                    _ = CGRequestScreenCaptureAccess()
                    open("Privacy_ScreenCapture")
                }
                permission("Contacts", granted: refresh >= 0 && CNContactStore.authorizationStatus(for: .contacts) == .authorized,
                           detail: "Search Contacts") {
                    CNContactStore().requestAccess(for: .contacts) { _, _ in DispatchQueue.main.async { refresh += 1 } }
                    open("Privacy_Contacts")
                }
                permission("Calendars", granted: refresh >= 0 && EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                           detail: "My Schedule, next meeting") {
                    EKEventStore().requestFullAccessToEvents { _, _ in DispatchQueue.main.async { refresh += 1 } }
                    open("Privacy_Calendars")
                }
            }
            Section("Clipboard History") {
                LabeledContent("Entries", value: "\(Clipboard.shared.count)")
                Button("Clear Clipboard History…") {
                    if confirm("Delete the whole clipboard history? This cannot be undone.") { Clipboard.shared.clear(); refresh += 1 }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permission(_ name: String, granted: Bool, detail: String, grant: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted { Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Button("Grant…", action: grant) }
        } label: {
            Text(name)
            Text(detail)
        }
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!)
    }
}

private struct AISettings: View {
    @AppStorage("aiEnabled") private var aiEnabled = false
    @AppStorage("aiProvider") private var provider = AIProvider.claude.rawValue
    @AppStorage("aiModel") private var model = ""
    @AppStorage("aiBaseURL") private var baseURL = ""
    @SettingsState private var key = ""
    @SettingsState private var keyVersion = 0
    @SettingsState private var testResult = ""

    private var current: AIProvider { AIProvider(rawValue: provider) ?? .claude }

    var body: some View {
        Form {
            Section("Optional AI") {
                Toggle("Enable AI", isOn: $aiEnabled)
                Text("Requests use your account or local server. Your provider may charge you. Set spending limits with your provider before sending paid requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider") {
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                TextField("Model", text: $model, prompt: Text(modelPrompt))
                if current == .compatible {
                    TextField("Base URL", text: $baseURL, prompt: Text("https://api.openai.com/v1 or http://localhost:11434/v1"))
                }
                if current == .chatgpt {
                    Text("Uses your ChatGPT subscription through the official Codex CLI. Sign in once in a terminal with `codex login`; Lumen never sees the credentials. Answers take a few seconds and arrive in one piece.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if current != .chatgpt { keySection }
            Section {
                HStack {
                    Button("Test Connection") { test() }.disabled(!aiEnabled)
                    Text(testResult).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modelPrompt: String {
        switch current {
        case .claude: return current.defaultModel
        case .compatible: return "e.g. the OpenAI or Ollama model name"
        case .chatgpt: return "Codex default"
        }
    }

    private var keySection: some View {
            Section("API Key") {
                HStack {
                    SecureField("API key", text: $key,
                                prompt: Text(keyVersion >= 0 && Keychain.get(provider) != nil ? "Saved in Keychain" : "Not set"))
                    Button("Save") {
                        Keychain.set(key, provider)
                        key = ""
                        keyVersion += 1
                    }
                }
                Text(current == .claude ? "Create a key at console.anthropic.com. It is stored in the macOS Keychain."
                                        : "Required for the OpenAI API (platform.openai.com), optional for local servers such as Ollama. Stored in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }

    private func test() {
        testResult = "Asking…"
        Task { @MainActor in
            var answer = ""
            do {
                try await AI.stream(system: "Reply with one short sentence.", prompt: "Say hello to Lumen.") { answer += $0 }
                testResult = "✓ " + answer
            } catch {
                testResult = "⚠️ " + error.localizedDescription
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text("Lumen").font(.largeTitle.weight(.semibold))
            Text("Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))
                .foregroundStyle(.secondary)
            Text("A native launcher for apps, files, commands, clipboard, calendar and AI.")
                .multilineTextAlignment(.center)
            Link("github.com/jsc2304/lumen", destination: URL(string: "https://github.com/jsc2304/lumen")!)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LauncherHotkeyRow: View {
    let index: Int
    @SettingsState private var binding: HotkeyBinding?
    @SettingsState private var monitor: Any?
    @SettingsState private var error = ""

    var body: some View {
        LabeledContent("Shortcut \(index + 1)") {
            HStack {
                Button(monitor != nil ? "Press shortcut…" : binding?.label ?? "Record Shortcut…") { start() }
                    .accessibilityLabel("Record launcher shortcut \(index + 1)")
                Button("Remove") { stop(); save(nil) }
                    .disabled(binding == nil)
            }
        }
        if monitor != nil {
            Text("Press ⌘, ⌥ or ⌃ with a key. Escape cancels.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        // The row owns its monitor only while it is visible and its window is active.
        Color.clear.frame(height: 0)
            .onAppear { binding = HotKeys.bindings()[index] }
            .onDisappear { stop() }
            .onReceive(NotificationCenter.default.publisher(for: .init("LumenRecorderStarted"))) { _ in stop() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
            .onReceive(NotificationCenter.default.publisher(for: .init("LumenHotkeysChanged"))) { _ in
                binding = HotKeys.bindings()[index]
            }
    }

    private func start() {
        stop()
        error = ""
        NotificationCenter.default.post(name: .init("LumenRecorderStarted"), object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let mods = event.modifierFlags.intersection(Shortcut.relevant)
            guard !mods.subtracting(.shift).isEmpty else {
                error = "Include Command, Option or Control."
                return nil
            }
            let key = event.keyCode == 49 ? "Space" : event.charactersIgnoringModifiers?.uppercased() ?? "?"
            stop()
            save(HotkeyBinding(keyCode: event.keyCode, modifiers: mods.rawValue,
                               label: Shortcut.symbols(mods) + key))
            return nil
        }
    }

    private func save(_ value: HotkeyBinding?) {
        error = HotKeys.setMain(value, at: index) ?? ""
        binding = HotKeys.bindings()[index]
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

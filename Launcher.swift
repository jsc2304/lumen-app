import AppKit

/// State of the panel: a stack of views (root search, lists, forms, AI answers) plus the ⌘K menu.
final class Launcher: ObservableObject {
    static let shared = Launcher()
    static let defaultDetailWidth: CGFloat = 438
    private static let detailWidthRange: ClosedRange<CGFloat> = 220...490

    enum Mode {
        case root, list(ListSpec), form(FormSpec), answer, recordHotkey(Item)
    }

    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published private(set) var items: [Item] = []
    @Published var selection = 0
    @Published private(set) var mode = Mode.root
    @Published var formValues: [String] = []
    @Published private(set) var formError = ""
    @Published private(set) var answerTitle = ""
    @Published private(set) var answer = ""
    @Published private(set) var answerError = ""
    @Published private(set) var answerActions: [Action] = []
    @Published private(set) var actionsOpen = false
    @Published private(set) var actionQuery = ""
    @Published var actionSelection = 0
    @Published var focusToken = 0
    @Published private(set) var detailVisible: Bool
    @Published private(set) var detailWidth: CGFloat

    private let preferences: UserDefaults

    private var stack: [(Mode, String)] = []
    private var aiTask: Task<Void, Never>?
    private var answering = false
    private var selectionWasChosen = false

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        detailVisible = preferences.object(forKey: "launcherDetailVisible") as? Bool ?? true
        let savedWidth = preferences.object(forKey: "launcherDetailWidth") as? Double
        detailWidth = Self.clampDetailWidth(savedWidth.map { CGFloat($0) } ?? Self.defaultDetailWidth)
    }

    var supportsDetail: Bool {
        if case .list(let spec) = mode { return spec.showsDetail }
        return false
    }

    static func clampDetailWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultDetailWidth }
        return min(max(width, detailWidthRange.lowerBound), detailWidthRange.upperBound)
    }

    func toggleDetail() {
        guard supportsDetail else { return }
        detailVisible.toggle()
        preferences.set(detailVisible, forKey: "launcherDetailVisible")
        if !detailVisible { focusToken += 1 }
    }

    func resizeDetail(to width: CGFloat) {
        detailWidth = Self.clampDetailWidth(width)
        preferences.set(Double(detailWidth), forKey: "launcherDetailWidth")
    }

    var selected: Item? { items.indices.contains(selection) ? items[selection] : nil }
    var isRoot: Bool { if case .root = mode { return true }; return false }
    var isForm: Bool { if case .form = mode { return true }; return false }

    var title: String {
        switch mode {
        case .root: return ""
        case .list(let spec): return spec.title
        case .form(let spec): return spec.title
        case .answer: return answerTitle
        case .recordHotkey(let item): return "Hotkey for " + item.title
        }
    }

    // MARK: Navigation

    func reset() {
        aiTask?.cancel()
        stack = []
        actionsOpen = false
        mode = .root
        query = ""
        refresh()
    }

    func push(_ m: Mode) {
        stack.append((mode, query))
        actionsOpen = false
        mode = m
        if case .form(let spec) = m {
            formValues = spec.fields.map(\.value)
            formError = ""
        }
        query = ""
        refresh()
        focusToken += 1
    }

    func pop() {
        aiTask?.cancel()
        actionsOpen = false
        guard let (previous, previousQuery) = stack.popLast() else { PanelController.shared.hide(); return }
        mode = previous
        query = previousQuery
        refresh()
        focusToken += 1
    }

    func refresh() {
        selectionWasChosen = false
        items = currentItems() ?? []
        if query.isEmpty, case .list(let spec) = mode, let initialSelection = spec.initialSelection {
            selection = min(max(initialSelection(items), 0), max(items.count - 1, 0))
        } else { selection = 0 }
    }

    /// Re-reads the current list after its data changed (file results, calendar access), keeping the selection.
    func reload() {
        guard let fresh = currentItems() else { return }
        applyReload(fresh)
    }

    func applyReload(_ fresh: [Item]) {
        let id = selected?.id
        items = fresh
        // Async results replace the default selection, but never a deliberate choice
        // or the target of an open action menu. Dedicated lists keep their selection.
        if isRoot && !selectionWasChosen && !actionsOpen {
            selection = 0
            return
        }
        // Stay on the same item; if it moved away, an open ⌘K menu would act on another one, so close it.
        if let id, let i = items.firstIndex(where: { $0.id == id }) {
            selection = i
        } else {
            if query.isEmpty, case .list(let spec) = mode, let initialSelection = spec.initialSelection {
                selection = min(max(initialSelection(items), 0), max(items.count - 1, 0))
            } else { selection = min(selection, max(items.count - 1, 0)) }
            actionsOpen = false
        }
    }

    private func currentItems() -> [Item]? {
        switch mode {
        case .root: return Root.items(for: query)
        case .list(let spec): return spec.items(query)
        default: return nil
        }
    }

    // MARK: Actions

    var currentActions: [Action] {
        switch mode {
        case .answer: return answerActions
        case .root, .list: return selected?.actions ?? []
        default: return []
        }
    }

    /// Actions matching the ⌘K search, with their position in the full list.
    var filteredActions: [(index: Int, action: Action)] {
        currentActions.enumerated().map { ($0.offset, $0.element) }
            .filter { actionQuery.isEmpty || matchScore(actionQuery, $0.1.title) > 0 }
    }

    func perform(_ action: Action, primary: Bool = false) {
        if primary, isRoot, let item = selected, item.track { Root.used(item, query: query) }
        actionsOpen = false
        if action.closes { PanelController.shared.hide() }
        action.run()
    }

    private func toggleActions() {
        selectionWasChosen = true
        guard !currentActions.isEmpty else { return }
        actionsOpen.toggle()
        actionQuery = ""
        actionSelection = 0
    }

    // MARK: Keyboard

    /// Handles a key press in the panel; returns false to let the focused text field take it.
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(Shortcut.relevant)
        let char = e.charactersIgnoringModifiers?.lowercased()
        if case .recordHotkey(let item) = mode { recordHotkey(e, for: item); return true }
        if actionsOpen { return handleActionMenuKey(e, mods) }
        if mods == [.command, .option], char == "i", supportsDetail {
            toggleDetail()
            return true
        }
        if mods == [.command, .option], supportsDetail, detailVisible {
            if e.keyCode == 123 { resizeDetail(to: detailWidth + 16); return true }
            if e.keyCode == 124 { resizeDetail(to: detailWidth - 16); return true }
        }
        if mods == .command, char == "k" { toggleActions(); return true }
        if mods == .command, char == "," { Settings.show(); return true }
        switch e.keyCode {
        case 53: escape(); return true
        case 126 where !isForm: move(-1); return true
        case 125 where !isForm: move(1); return true
        case 36, 76:
            if isForm {
                guard mods == .command else { return false }
                submitForm()
                return true
            }
            let action = mods == .command ? Action.secondary(of: currentActions) : currentActions.first
            if let action { perform(action, primary: true) }
            return true
        case 48 where isRoot && !query.trimmingCharacters(in: .whitespaces).isEmpty:
            askAI(query)
            return true
        default:
            guard let action = currentActions.first(where: { $0.shortcut?.matches(e) == true }) else { return false }
            perform(action)
            return true
        }
    }

    private func handleActionMenuKey(_ e: NSEvent, _ mods: NSEvent.ModifierFlags) -> Bool {
        let actions = filteredActions
        switch e.keyCode {
        case 53: actionsOpen = false
        case 126: if !actions.isEmpty { actionSelection = (actionSelection - 1 + actions.count) % actions.count }
        case 125: if !actions.isEmpty { actionSelection = (actionSelection + 1) % actions.count }
        case 36, 76: if actions.indices.contains(actionSelection) { perform(actions[actionSelection].action) }
        case 51: if !actionQuery.isEmpty { actionQuery.removeLast(); actionSelection = 0 }
        default:
            if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "k" { actionsOpen = false; return true }
            if let action = currentActions.first(where: { $0.shortcut?.matches(e) == true }) { perform(action); return true }
            // Typing filters the menu; arrow and function keys produce private-use characters, skip those.
            if mods.subtracting(.shift).isEmpty, let c = e.characters,
               c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) {
                actionQuery += c
                actionSelection = 0
            }
        }
        return true
    }

    func chooseSelection(_ index: Int) {
        selectionWasChosen = true
        selection = index
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        chooseSelection((selection + delta + items.count) % items.count)
    }

    private func escape() {
        switch mode {
        case .root:
            if query.isEmpty { PanelController.shared.hide() } else { query = "" }
        case .list:
            if query.isEmpty { pop() } else { query = "" }
        default:
            pop()
        }
    }

    private func submitForm() {
        guard case .form(let spec) = mode else { return }
        if let error = spec.onSubmit(formValues) { formError = error } else { pop() }
    }

    private static let keyNames: [UInt16: String] = [
        49: "Space", 36: "↵", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘",
        116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private func recordHotkey(_ e: NSEvent, for item: Item) {
        let mods = e.modifierFlags.intersection(Shortcut.relevant)
        if e.keyCode == 53 { pop(); return }
        if e.keyCode == 51, mods.isEmpty { Root.setHotkey(nil, for: item); pop(); return }
        guard !mods.subtracting(.shift).isEmpty else { NSSound.beep(); return }   // needs ⌘, ⌥ or ⌃
        let key = Self.keyNames[e.keyCode] ?? e.charactersIgnoringModifiers?.uppercased() ?? "?"
        Root.setHotkey(HotkeyBinding(keyCode: e.keyCode, modifiers: mods.rawValue, label: Shortcut.symbols(mods) + key), for: item)
        pop()
    }

    // MARK: AI

    func askAI(_ question: String) {
        ask(title: question, system: "You answer quick questions inside a macOS launcher. Be brief; use Markdown only when it helps.",
            prompt: question, primary: ("Copy Answer", { copyToClipboard($0); HUD.show("Copied to Clipboard") }),
            secondary: ("Paste Answer", { Clipboard.shared.paste(text: $0) }))
    }

    func runAICommand(_ c: AICommand) {
        if let text = AX.selectedText() { startCommand(c, text); return }
        // Browsers and Electron apps expose no selected text over Accessibility: copy it instead.
        PanelController.shared.hide()
        Clipboard.shared.captureSelection { [weak self] text in
            PanelController.shared.show(reset: false)
            self?.startCommand(c, text ?? "")
        }
    }

    private func startCommand(_ c: AICommand, _ text: String) {
        let paste: (String, (String) -> Void) = ("Paste Result", { Clipboard.shared.paste(text: $0) })
        let copy: (String, (String) -> Void) = ("Copy Result", { copyToClipboard($0); HUD.show("Copied to Clipboard") })
        guard !text.isEmpty else {
            push(.answer)
            answerTitle = c.title
            answer = ""
            answerError = "No selected text found. Select text in an app first, then run this command."
            answerActions = []
            return
        }
        // Like Raycast, a prompt may place the text with {selection}; otherwise it is appended.
        let selection = AI.untrustedText(text)
        let prompt = c.prompt.contains("{selection}")
            ? c.prompt.replacingOccurrences(of: "{selection}", with: selection)
            : c.prompt + "\n\n" + selection
        ask(title: c.title, system: aiCommandSystem, prompt: prompt,
            primary: c.replaces ? paste : copy, secondary: c.replaces ? copy : paste)
    }

    private func ask(title: String, system: String, prompt: String,
                     primary: (String, (String) -> Void), secondary: (String, (String) -> Void)) {
        aiTask?.cancel()
        push(.answer)
        answerTitle = title
        answer = ""
        answerError = ""
        answering = true
        // Paste and copy only a complete answer: never a half-streamed one or nothing over the user's selection.
        let finish: ((String) -> Void) -> Void = { [weak self] use in
            guard let self, !self.answering, self.answerError.isEmpty, !self.answer.isEmpty else { NSSound.beep(); return }
            PanelController.shared.hide()
            use(self.answer)
        }
        answerActions = [
            Action(title: primary.0, icon: "doc.on.doc", closes: false) { finish(primary.1) },
            Action(title: secondary.0, icon: "doc.on.clipboard", closes: false) { finish(secondary.1) },
            Action(title: "Continue in Chat", icon: "bubble.left.and.text.bubble.right", shortcut: Shortcut(.command, "j"),
                   closes: false) { finish { AIChat.open(question: prompt, answer: $0) } },
            Action(title: "Ask Again", icon: "arrow.clockwise", shortcut: Shortcut(.command, "r"), closes: false) { [weak self] in
                self?.pop()
                self?.ask(title: title, system: system, prompt: prompt, primary: primary, secondary: secondary)
            },
        ]
        aiTask = Task { @MainActor [weak self] in
            do {
                try await AI.stream(system: system, prompt: prompt) { self?.answer += $0 }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.answerError = error.localizedDescription }
            }
            if !Task.isCancelled { self?.answering = false }
        }
    }
}

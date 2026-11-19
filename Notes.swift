import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Raycast Notes: quick Markdown notes in a floating window, searchable from Lumen.
final class Notes: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = Notes()

    /// One note in notes.json.
    struct Note: Codable, Equatable {
        var id: String
        var text: String
        var created: Date
        var modified: Date

        init(text: String = "") {
            id = UUID().uuidString
            self.text = text
            created = Date()
            modified = created
        }

        // Every key optional, so a notes.json written before a field existed still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
            modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        }

        /// The first non-empty line without its leading #, at most 200 characters: a note that is one huge line
        /// must not cost a scan of it for every keystroke (the title is matched, shown and set as the window title).
        var title: String {
            var rest = text[...]
            while !rest.isEmpty {
                let line = rest.prefix(200).prefix { !$0.isNewline }
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty {
                    let heading = String(t.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    return heading.isEmpty ? "Untitled" : heading
                }
                guard let newline = rest[line.endIndex...].firstIndex(where: \.isNewline) else { break }   // blank so far: next line
                rest = rest[rest.index(after: newline)...]
            }
            return "Untitled"
        }

        var isBlank: Bool { text.allSatisfy(\.isWhitespace) }

        /// Whitespace-separated pieces with a letter or digit in them, so Markdown marks (#, -, >) do not count.
        /// Walks the unicode scalars without allocating: the list builds it for every note and the footer for every keystroke.
        var wordCount: Int {
            var n = 0, counted = false
            for s in text.unicodeScalars {
                if s.properties.isWhitespace {
                    counted = false
                } else if !counted, s.properties.isAlphabetic || s.properties.numericType != nil {
                    counted = true
                    n += 1
                }
            }
            return n
        }

        var fileName: String { String(title.map { "/:".contains($0) ? "-" : $0 }.prefix(80)) + ".md" }
    }

    @Published private(set) var notes: [Note] = Store.load("notes.json") ?? [] { didSet { syncTitle() } }
    @Published private(set) var currentID: String? { didSet { syncTitle() } }
    @Published private(set) var switcherOpen = false
    @Published var switcherQuery = "" { didSet { switcherSelection = 0 } }
    @Published var switcherSelection = 0
    @Published var floats = UserDefaults.standard.object(forKey: "notesFloat") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(floats, forKey: "notesFloat")
            window?.level = floats ? .floating : .normal
        }
    }

    fileprivate weak var editor: NSTextView?
    private var window: LauncherPanel?
    private var saves = 0   // counts edits and saves; a scheduled save runs only if nothing came after it

    private static let frameName = "LumenNotes"

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.save()
        }
    }

    // MARK: Commands

    static func commands() -> [Item] {
        [.command("notes.open", "Lumen Notes", icon: "note.text", keywords: ["notes", "notizen", "markdown", "scratchpad", "memo"]) {
            shared.open()
         },
         .command("notes.create", "Create Note", icon: "square.and.pencil", keywords: ["note", "new", "notiz", "neue notiz"]) {
            shared.create()
         },
         .command("notes.search", "Search Notes", icon: "magnifyingglass", keywords: ["notes", "find", "notizen", "suchen"], closes: false) {
            Launcher.shared.push(.list(ListSpec(title: "Notes", placeholder: "Search notes…", showsDetail: true) {
                listItems(shared.notes, $0)
            }))
         }]
    }

    /// Non-empty notes matching the query, best match first, then the most recently edited.
    static func matching(_ notes: [Note], _ query: String) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Scored once per note, then sorted: scoring inside the comparator searched every text again for each comparison.
        let scored = notes.compactMap { n -> (note: Note, score: Double)? in
            guard !n.isBlank else { return nil }
            let score = q.isEmpty ? 1 : max(matchScore(q, n.title), n.text.localizedCaseInsensitiveContains(q) ? 30 : 0)
            return score > 0 ? (n, score) : nil
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.note.modified > $1.note.modified }.map(\.note)
    }

    static func listItems(_ notes: [Note], _ query: String) -> [Item] {
        let create = Action(title: "Create Note", icon: "square.and.pencil", shortcut: Shortcut(.command, "n")) { shared.create() }
        let found = matching(notes, query)
        guard !found.isEmpty else {
            return [Item(id: "notes.none", title: query.isEmpty ? "No notes yet" : "No matching notes",
                         icon: .symbol("note.text"), track: false, actions: [create])]
        }
        return found.map { n in
            Item(id: "notes.note." + n.id, title: n.title, kind: n.modified.formatted(.relative(presentation: .named)),
                 icon: .symbol("note.text"), track: false,
                 actions: [
                    Action(title: "Open Note", icon: "square.and.pencil") { shared.open(n.id) },
                    .copy("Copy Note", shortcut: Shortcut([.command, .shift], "c")) { n.text },
                    Action(title: "Delete Note", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false) {
                        shared.delete(n.id)
                    },
                    Action(title: "Export as Markdown…", icon: "square.and.arrow.up") { shared.export(n) },
                    create,
                 ],
                 detail: Detail(markdown: n.text, metadata: [
                    ("Words", "\(n.wordCount)"),
                    ("Modified", n.modified.formatted(date: .abbreviated, time: .shortened)),
                    ("Created", n.created.formatted(date: .abbreviated, time: .shortened)),
                 ]))
        }
    }

    // MARK: Notes

    private var currentIndex: Int? { notes.firstIndex { $0.id == currentID } }
    fileprivate var current: Note? { currentIndex.map { notes[$0] } }
    private var windowTitle: String { current?.title ?? "Notes" }
    private func syncTitle() { if let w = window, w.title != windowTitle { w.title = windowTitle } }
    private var lastEdited: Note? { notes.filter { !$0.isBlank }.max { $0.modified < $1.modified } }

    /// Opens the window on a note: the given one, or the last edited, or a new one. Already open: just brings it forward.
    func open(_ id: String? = nil) {
        guard id != nil || window?.isVisible != true else { return present() }
        guard let target = id ?? lastEdited?.id else { return create() }
        leave()
        currentID = target
        present()
    }

    /// Opens the window on a new note, optionally starting with a copy of some text.
    func create(_ text: String = "") {
        leave()
        let note = Note(text: text)
        notes.append(note)
        currentID = note.id
        scheduleSave()
        present()
    }

    func edit(_ text: String) {
        guard let i = currentIndex, notes[i].text != text else { return }
        var note = notes[i]
        note.text = text
        note.modified = Date()
        notes[i] = note
        scheduleSave()
    }

    func delete(_ id: String) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        if !note.isBlank {
            let ok = confirmDelete("Delete the note “\(note.title)”?")
            PanelController.shared.show(reset: false)   // the alert took the focus, which hid the panel
            guard ok else { return }
        }
        notes.removeAll { $0.id == id }
        save()
        if currentID == id {
            if let next = lastEdited { currentID = next.id } else { create() }
        }
        Launcher.shared.reload()
    }

    /// Cancel is the default button (↵ and esc), so a stray key press never deletes a note.
    private func confirmDelete(_ question: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Called before another note takes the window and when it closes: drops an empty note and writes pending edits.
    private func leave() {
        switcherOpen = false
        if let i = currentIndex, notes[i].isBlank { notes.remove(at: i) }
        save()
    }

    // MARK: Saving

    private func scheduleSave() {
        saves += 1
        let token = saves
        later(0.5) { [self] in if saves == token { save() } }
    }

    private func save() {
        saves += 1   // a scheduled save still waiting has nothing left to write
        Store.save(notes.filter { !$0.isBlank }, "notes.json")
    }

    func export(_ note: Note) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.fileName
        if let markdown = UTType(filenameExtension: "md") { panel.allowedContentTypes = [markdown] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(note.text.utf8).write(to: url, options: .atomic)
            HUD.show("Exported Note")
        } catch {
            HUD.show("Export failed: " + error.localizedDescription)
        }
    }

    // MARK: Switcher (⌘P)

    var switcherItems: [Note] { Self.matching(notes, switcherQuery) }

    func toggleSwitcher() {
        if switcherOpen { return closeSwitcher() }
        switcherQuery = ""
        switcherOpen = true
    }

    func closeSwitcher() {
        switcherOpen = false
        focusEditor()
    }

    // MARK: Window

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            if let tv = self?.editor { tv.window?.makeFirstResponder(tv) }
        }
    }

    private func present() {
        let w = window ?? makeWindow()
        window = w
        w.title = windowTitle
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        focusEditor()
    }

    private func makeWindow() -> LauncherPanel {
        let w = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = floats ? .floating : .normal
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 320, height: 220)
        w.delegate = self
        w.onKey = { [weak self] in self?.handleKey($0) ?? false }

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        w.contentView = blur
        // Pinned to the area below the transparent title bar; the blur itself runs under it.
        let host = NSHostingView(rootView: NotesView(model: self))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        if let area = w.contentLayoutGuide as? NSLayoutGuide {
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: area.topAnchor), host.bottomAnchor.constraint(equalTo: area.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: area.leadingAnchor), host.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            ])
        }
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        return w
    }

    func windowWillClose(_ notification: Notification) {
        leave()
        currentID = nil
        // An accessory app stays active without a window and would swallow the next keystrokes.
        if !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.deactivate() }
    }

    // MARK: Keyboard

    private lazy var shortcuts: [(Shortcut, () -> Void)] = [
        (Shortcut(.command, "n"), { [self] in create() }),
        (Shortcut(.command, "d"), { [self] in if let text = current?.text { create(text) } }),
        (Shortcut(.command, "p"), { [self] in toggleSwitcher() }),
        (Shortcut(.command, "o"), { [self] in toggleSwitcher() }),
        (Shortcut([.command, .shift], "c"), { [self] in
            guard let text = current?.text else { return }
            copyToClipboard(text)
            HUD.show("Copied to Clipboard")
        }),
        (Shortcut(.command, "w"), { [self] in window?.performClose(nil) }),
    ]

    /// Window shortcuts and, while the switcher is open, its navigation keys; false lets the focused field take the key.
    private func handleKey(_ e: NSEvent) -> Bool {
        if switcherOpen {
            let items = switcherItems
            switch e.keyCode {
            case 53: closeSwitcher(); return true
            case 126, 125:
                if !items.isEmpty { switcherSelection = (switcherSelection + (e.keyCode == 125 ? 1 : items.count - 1)) % items.count }
                return true
            case 36, 76:
                if items.indices.contains(switcherSelection) { open(items[switcherSelection].id) }
                return true
            default: break
            }
        }
        guard !e.isARepeat, let (shortcut, run) = shortcuts.first(where: { $0.0.matches(e) }),
              !switcherOpen || shortcut.key == "p" || shortcut.key == "o" else { return false }
        run()
        return true
    }
}

// MARK: Markdown styling

extension Notes {
    enum Style: Equatable { case heading(Int), marker }

    private static let headingLine = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t].*$", options: .anchorsMatchLines)
    private static let listMarker = try! NSRegularExpression(pattern: "^[ \\t]*([-*+]|\\d+[.)])(?=[ \\t])", options: .anchorsMatchLines)

    /// Headings (the whole line, with their level) and list markers (bullet or number only).
    static func styles(_ text: String) -> [(range: NSRange, style: Style)] {
        let all = NSRange(text.startIndex..., in: text)
        var result: [(range: NSRange, style: Style)] = []
        headingLine.enumerateMatches(in: text, range: all) { m, _, _ in
            if let m { result.append((m.range, .heading(m.range(at: 1).length))) }
        }
        listMarker.enumerateMatches(in: text, range: all) { m, _, _ in
            if let m { result.append((m.range(at: 1), .marker)) }
        }
        return result
    }
}

/// The Markdown editor: a plain NSTextView, restyled after every edit.
private struct NoteEditor: NSViewRepresentable {
    let id: String
    let text: String
    let edit: (String) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        static let body = NSFont.systemFont(ofSize: 14)
        var id = ""
        var edit: (String) -> Void = { _ in }

        func textDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView { edit(tv.string) }
        }

        // ponytail: restyles the whole note on every edit, fine up to ~100 KB; style only the edited paragraphs beyond that
        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
            guard mask.contains(.editedCharacters) else { return }
            storage.addAttributes([.font: Self.body, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: storage.length))
            for (range, style) in Notes.styles(storage.string) {
                switch style {
                case .heading(let level):
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: level <= 3 ? [22, 18, 16][level - 1] : 14, weight: .bold), range: range)
                case .marker:
                    storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let tv = scroll.documentView as! NSTextView
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Coordinator.body
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 14, height: 12)
        // Markdown is typed as is: no smart quotes, dashes or text replacements.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
        Notes.shared.editor = tv
        Notes.shared.focusEditor()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.edit = edit
        if tv.string != text { tv.string = text }
        guard context.coordinator.id != id else { return }
        // Another note: its own undo history, caret at the end to carry on writing.
        context.coordinator.id = id
        tv.undoManager?.removeAllActions()
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
    }
}

private struct NotesView: View {
    @ObservedObject var model: Notes
    @SwiftUI.FocusState private var searchFocused: Bool   // qualified: Focus.swift declares its own FocusState

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                NoteEditor(id: model.currentID ?? "", text: model.current?.text ?? "") { model.edit($0) }
                Divider()
                footer
            }
            if model.switcherOpen { switcher }
        }
    }

    private var footer: some View {
        let words = model.current?.wordCount ?? 0, characters = model.current?.text.count ?? 0
        return HStack(spacing: 14) {
            Text("\(words) \(words == 1 ? "word" : "words") · \(characters) \(characters == 1 ? "character" : "characters")")
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Float on top", isOn: $model.floats).toggleStyle(.checkbox)
            Divider().frame(height: 16)
            hint("Notes", "⌘P") { model.toggleSwitcher() }
            hint("New", "⌘N") { model.create() }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private func hint(_ label: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                Text(key).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .buttonStyle(.plain)
    }

    private var switcher: some View {
        let items = model.switcherItems
        return ZStack(alignment: .top) {
            Color.black.opacity(0.001).onTapGesture { model.closeSwitcher() }
            VStack(spacing: 0) {
                TextField("Switch to note…", text: $model.switcherQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                Divider()
                if items.isEmpty {
                    Text("No notes").foregroundStyle(.secondary).frame(height: 40)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, note in
                                    HStack {
                                        Text(note.title).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(note.modified.formatted(.relative(presentation: .named))).font(.callout).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(i == model.switcherSelection ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                    .id(i)
                                    .onTapGesture { model.open(note.id) }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 240)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: model.switcherSelection) { proxy.scrollTo(model.switcherSelection) }
                    }
                }
            }
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
            .padding(.top, 12)
            .padding(.horizontal, 12)
            .onAppear { searchFocused = true }
        }
    }
}

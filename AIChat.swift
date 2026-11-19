import AppKit
import SwiftUI

/// AI Chat: a window with saved multi-turn conversations, plus the root commands that send the selection,
/// a window, the screen or a screen area into a new chat.
final class AIChat: NSObject, ObservableObject, NSWindowDelegate {
    static let shared: AIChat = {
        let chat = AIChat()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak chat] _ in
            chat?.flushPendingWrites()
        }
        return chat
    }()

    struct Conversation: Codable, Identifiable {
        var id = UUID()
        var date = Date()   // last message: the list shows the newest first
        var messages: [AIMessage] = []

        var title: String { AIChat.title(messages.first) }
    }

    // ponytail: images live inline in ai-chats.json (base64, downscaled to 1920 px); move them to files next to it
    // if heavy screenshot use makes the file slow to load.
    @Published private(set) var chats: [Conversation]
    @Published var current: UUID?   // nil: a new chat that is saved with its first message
    @Published var input = ""
    @Published var attachments: [Data] = []
    @Published private(set) var streaming = false
    @Published private(set) var replyChat: UUID?   // the chat that `reply` and `error` belong to
    @Published private(set) var reply = ""
    @Published private(set) var error = ""
    @Published private(set) var focusToken = 0

    private var task: Task<Void, Never>?
    private var window: NSWindow?
    private let disk = DispatchQueue(label: "Lumen AI chats")
    private let persist: ([Conversation]) -> Void

    // Injectable persistence keeps checks away from the user's chat archive.
    init(chats: [Conversation] = Store.load("ai-chats.json") ?? [],
         persist: @escaping ([Conversation]) -> Void = { Store.save($0, "ai-chats.json") }) {
        self.chats = chats
        self.persist = persist
        super.init()
    }

    private static let system = "You are a helpful assistant in a chat window of a macOS launcher. Format with inline Markdown only "
        + "(bold, italics, code, links); headings and tables are not rendered."

    var conversation: Conversation? { chats.first { $0.id == current } }

    // MARK: Entry points

    /// Opens the window on the conversation shown last, or the newest one.
    static func show() {
        shared.current = shared.current ?? shared.chats.first?.id
        shared.present()
    }

    static func open(_ id: UUID) {
        shared.current = id
        shared.present()
    }

    /// Continues a Quick AI exchange as a chat (Launcher's "Continue in Chat").
    static func open(question: String, answer: String) {
        shared.add(Conversation(messages: [AIMessage(role: .user, text: question), AIMessage(role: .assistant, text: answer)]))
        shared.present()
    }

    /// A new chat with `text` and `images` waiting in the input, for the user to add the question.
    /// An unsent draft is kept instead: the quote goes below it, the images join its attachments.
    static func start(text: String = "", images: [Data] = []) {
        if shared.input.isEmpty && shared.attachments.isEmpty { shared.newChat() }
        shared.input = appending(text, to: shared.input)
        shared.attachments += images
        shared.present()
    }

    /// `input` with `text` below it, a blank line between.
    static func appending(_ text: String, to input: String) -> String {
        guard !input.isEmpty, !text.isEmpty else { return input + text }
        return input + (input.hasSuffix("\n\n") ? "" : input.hasSuffix("\n") ? "\n" : "\n\n") + text
    }

    private func present() {
        PanelController.shared.hide()
        if window == nil {
            let host = NSHostingController(rootView: ChatView(model: self))
            host.sizingOptions = [.minSize]   // otherwise the window snaps back to the view's ideal size
            let w = NSWindow(contentViewController: host)
            w.title = "AI Chat"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 860, height: 600))
            if !w.setFrameUsingName("Lumen AI Chat") { w.center() }
            w.setFrameAutosaveName("Lumen AI Chat")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusToken += 1
    }

    func windowWillClose(_ notification: Notification) {
        // An accessory app stays active without a window, so the next panel use would see Lumen as the frontmost app.
        if !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.deactivate() }
    }

    // MARK: Conversations

    func newChat() {
        current = nil
        input = ""
        attachments = []
        focusToken += 1
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streaming, !text.isEmpty || !attachments.isEmpty else { return }
        let message = AIMessage(role: .user, text: text, images: attachments)
        input = ""
        attachments = []
        if let id = conversation?.id { append(message, to: id) } else { add(Conversation(messages: [message])) }
        answer()
    }

    /// Asks again after an error. A broken-off answer saved before the error is dropped, so the question is the last message again.
    func retry() {
        guard !streaming, let c = conversation, replyChat == c.id, !error.isEmpty else { return }
        if c.messages.last?.role == .assistant, let i = chats.firstIndex(where: { $0.id == c.id }) {
            chats[i].messages.removeLast()
            save()
        }
        guard conversation?.messages.last?.role == .user else { return }
        answer()
    }

    func stop() { task?.cancel() }

    func delete(_ id: UUID) {
        if replyChat == id { task?.cancel() }
        chats.removeAll { $0.id == id }
        if current == id { current = chats.first?.id }
        save()
    }

    private func answer() {
        guard let c = conversation else { return }
        replyChat = c.id
        reply = ""
        error = ""
        streaming = true
        task = Task { @MainActor [weak self] in
            do {
                try await AI.stream(system: Self.system, messages: Self.sent(c.messages)) { self?.reply += $0 }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.error = error.localizedDescription }
            }
            self?.finish(c.id)
        }
    }

    /// The messages as sent to the model: only the last `keep` user messages with images carry them, older ones say so instead.
    /// Otherwise every turn would upload every earlier screenshot again. The chat keeps and shows all images.
    static func sent(_ messages: [AIMessage], keep: Int = 3) -> [AIMessage] {
        var left = keep
        let newestFirst = messages.reversed().map { m -> AIMessage in
            guard !m.images.isEmpty else { return m }
            if left > 0 {
                left -= 1
                return m
            }
            return AIMessage(role: m.role, text: m.text.isEmpty ? "[image omitted]" : m.text + "\n[image omitted]")
        }
        return Array(newestFirst.reversed())
    }

    /// Saves the answer, also a stopped or broken-off one (Try Again drops that one); an error stays on screen only.
    private func finish(_ id: UUID) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { append(AIMessage(role: .assistant, text: text), to: id) }
        reply = ""
        streaming = false
        task = nil
    }

    func add(_ c: Conversation) {
        chats.insert(c, at: 0)
        current = c.id
        save()
    }

    private func append(_ m: AIMessage, to id: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }   // deleted while the answer streamed
        var c = chats.remove(at: i)
        c.messages.append(m)
        c.date = Date()
        chats.insert(c, at: 0)
        save()
    }

    func flushPendingWrites() { disk.sync {} }

    private func save() {
        let snapshot = chats
        let persist = persist
        disk.async { persist(snapshot) }
    }

    /// A chat's name: the first line of its first message without quote marks, at most 60 characters.
    static func title(_ first: AIMessage?) -> String {
        let line = first?.text.split(whereSeparator: \.isNewline)
            .map { $0.drop { $0 == ">" || $0.isWhitespace } }
            .first { !$0.isEmpty }
        guard let line else { return first?.images.isEmpty == false ? "Image" : "New Chat" }
        return line.count > 60 ? line.prefix(59).trimmingCharacters(in: .whitespaces) + "…" : String(line)
    }

    static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
    }

    /// The conversation as Markdown, for copying and the panel's detail pane. With a `limit` it stops building
    /// once that many characters exist and returns at most that many.
    static func transcript(_ c: Conversation, limit: Int = .max) -> String {
        var parts: [String] = [], length = 0
        for m in c.messages where length < limit {
            let part = (m.role == .user ? "**You:** " : "**AI:** ") + String(m.text.prefix(limit)) + (m.images.isEmpty ? "" : " _[image]_")
            parts.append(part)
            length += part.count + 2
        }
        return String(parts.joined(separator: "\n\n").prefix(limit))
    }

    /// The first image of a chat for the panel's detail pane. Cached: the list is rebuilt on every keystroke,
    /// and decoding a screenshot per chat each time is slow. The message count in the key renews it when the chat grows.
    static func firstImage(of c: Conversation) -> NSImage? {
        let key = "\(c.id)|\(c.messages.count)" as NSString
        if let hit = thumbnails.object(forKey: key) { return hit }
        guard let data = c.messages.lazy.flatMap(\.images).first, let image = NSImage(data: data) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 30
        return cache
    }()

    // MARK: Root commands

    static func commands() -> [Item] {
        [
            .command("ai.chat", "AI Chat", kind: "AI Chat", icon: "bubble.left.and.text.bubble.right",
                     keywords: ["ai", "chat", "claude", "gpt", "conversation", "ask"]) { show() },
            .command("ai.chats", "Search AI Chats", kind: "AI Chat", icon: "text.bubble",
                     keywords: ["ai", "chat", "history", "conversations", "verlauf"], closes: false) {
                Launcher.shared.push(.list(ListSpec(title: "AI Chats", placeholder: "Search AI chats…", showsDetail: true) { items($0) }))
            },
            .command("ai.send-selection", "Send Selected Text to AI", kind: "AI Chat", icon: "text.quote",
                     keywords: ["ai", "chat", "selection", "selected", "auswahl", "ask"]) { sendSelection() },
            .command("ai.send-window", "Send Focused Window to AI", kind: "AI Chat", icon: "macwindow",
                     keywords: ["ai", "chat", "screenshot", "window", "fenster"]) { sendWindow() },
            .command("ai.send-screen", "Send Screen to AI", kind: "AI Chat", icon: "display",
                     keywords: ["ai", "chat", "screenshot", "screen", "bildschirm"]) { sendScreen() },
            .command("ai.send-area", "Send Screen Area to AI", kind: "AI Chat", icon: "rectangle.dashed",
                     keywords: ["ai", "chat", "screenshot", "area", "region", "bereich"]) { capture(["-i", "-s"], interactive: true) },
        ]
    }

    private static func items(_ q: String) -> [Item] {
        let date = RelativeDateTimeFormatter()
        return shared.chats.filter { c in q.isEmpty || c.messages.contains { $0.text.localizedCaseInsensitiveContains(q) } }
            .map { c in
                Item(id: "ai.chat." + c.id.uuidString, title: c.title, kind: date.localizedString(for: c.date, relativeTo: Date()),
                     icon: .symbol("bubble.left.and.bubble.right"), track: false,
                     actions: [
                        Action(title: "Open in AI Chat", icon: "bubble.left.and.text.bubble.right") { open(c.id) },
                        .copy("Copy Conversation") { transcript(c) },
                        Action(title: "Delete Chat", icon: "trash", shortcut: Shortcut(.control, "x"), destructive: true, closes: false) {
                            if confirm("Delete the chat “\(c.title)”? This cannot be undone.") { shared.delete(c.id) }
                            PanelController.shared.show(reset: false)   // the alert took the focus, which hid the panel
                            Launcher.shared.reload()
                        },
                     ],
                     detail: Detail(markdown: transcript(c, limit: 20_000), image: firstImage(of: c),
                                    metadata: [("Messages", "\(c.messages.count)"),
                                               ("Updated", c.date.formatted(date: .abbreviated, time: .shortened))]))
            }
    }

    // MARK: Sending context

    private static func sendSelection() {
        if let text = AX.selectedText() { startQuoted(text); return }
        // Browsers and Electron apps expose no selected text over Accessibility: copy it instead.
        Clipboard.shared.captureSelection { startQuoted($0 ?? "") }
    }

    private static func startQuoted(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { HUD.show("No selected text found"); return }
        start(text: quote(text))
    }

    private static func sendWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let id = frontWindow(in: list, pid: app.processIdentifier) else { HUD.show("No window to send"); return }
        capture(["-o", "-l", String(id)])
    }

    /// The frontmost normal window (layer 0) of the app `pid`; the window list runs front to back.
    static func frontWindow(in list: [[String: Any]], pid: pid_t) -> Int? {
        list.first { $0[kCGWindowOwnerPID as String] as? Int == Int(pid) && $0[kCGWindowLayer as String] as? Int == 0 }?[kCGWindowNumber as String] as? Int
    }

    private static func sendScreen() {
        // screencapture -D counts displays from 1 in the order of the active display list (main display first).
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let mouse = screenWithMouse()?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        capture(["-D", String((ids.prefix(Int(count)).firstIndex { $0 == mouse } ?? 0) + 1)])
    }

    private static let permissionHint = "Allow Lumen in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Lumen"

    /// Runs /usr/sbin/screencapture off the main thread into a temp file and opens a new chat with the PNG attached.
    private static func capture(_ args: [String], interactive: Bool = false) {
        // Without the permission a capture shows only the wallpaper; the request adds Lumen to the list and asks once.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            HUD.show(permissionHint)
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {   // the hidden panel is off the screen by then
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x"] + args + [file.path]
            if (try? p.run()) != nil { p.waitUntilExit() }
            let png = (try? Data(contentsOf: file)).flatMap(fitted)
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                if let png { start(images: [png]) } else if !interactive { HUD.show(permissionHint) }   // esc ends an area capture empty
            }
        }
    }

    /// The PNG at most 1920 px on the long edge (1080p: Anthropic's balance of detail and cost for screenshots);
    /// a Retina capture at full size costs several times the tokens and can pass the API's size limit per image.
    static func fitted(_ png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1920,
              ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

// MARK: Window

private struct ChatView: View {
    private static let defaultSidebarWidth = 230.0

    @ObservedObject var model: AIChat
    @AppStorage("aiChatSidebarVisible") private var sidebarVisible = true
    @AppStorage("aiChatSidebarWidth") private var sidebarWidth = ChatView.defaultSidebarWidth
    @FocusState private var dividerFocused: Bool
    @GestureState private var sidebarDragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { sidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(sidebarVisible ? Color.accentColor : Color.secondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("i", modifiers: [.option, .command])
                .help(sidebarVisible ? "Hide chat history (⌥⌘I)" : "Show chat history (⌥⌘I)")
                .accessibilityLabel(sidebarVisible ? "Hide chat history" : "Show chat history")
                Button { model.newChat() } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                Spacer()
            }
            .padding(.horizontal, 8)
            Divider()
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar.frame(width: Self.clampSidebarWidth(effectiveSidebarWidth + Double(sidebarDragOffset)))
                    sidebarDivider
                }
                VStack(spacing: 0) {
                    thread
                    Divider()
                    composer
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var sidebar: some View {
        List(selection: $model.current) {
            ForEach(model.chats) { c in
                Text(c.title).lineLimit(1)
                    .contextMenu { Button("Delete Chat…", role: .destructive) { delete(c) } }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let c = model.conversation { delete(c) } }
    }

    private static func clampSidebarWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultSidebarWidth }
        return min(max(width, 160), 340)
    }

    private var effectiveSidebarWidth: Double { Self.clampSidebarWidth(sidebarWidth) }

    private var sidebarDivider: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
            Capsule()
                .fill(dividerFocused ? Color.accentColor : Color.secondary.opacity(0.7))
                .frame(width: 3, height: 26)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .background(dividerFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .focusable()
        .focused($dividerFocused)
        .onKeyPress(.leftArrow) { adjustSidebar(by: -16); return .handled }
        .onKeyPress(.rightArrow) { adjustSidebar(by: 16); return .handled }
        .onTapGesture(count: 2) { sidebarWidth = Self.defaultSidebarWidth }
        .gesture(
            DragGesture(coordinateSpace: .global)
                .updating($sidebarDragOffset) { value, offset, _ in offset = value.translation.width }
                .onEnded { value in adjustSidebar(by: Double(value.translation.width)) }
        )
        .help("Drag or use the left and right arrow keys when focused. Double-click to reset.")
        .accessibilityLabel("Chat history width")
        .accessibilityValue("\(Int(effectiveSidebarWidth)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustSidebar(by: 16)
            case .decrement: adjustSidebar(by: -16)
            @unknown default: break
            }
        }
    }

    private func adjustSidebar(by points: Double) {
        sidebarWidth = Self.clampSidebarWidth(effectiveSidebarWidth + points)
    }

    private func delete(_ c: AIChat.Conversation) {
        if confirm("Delete the chat “\(c.title)”? This cannot be undone.") { model.delete(c.id) }
    }

    private var thread: some View {
        let messages = model.conversation?.messages ?? []
        let here = model.replyChat != nil && model.replyChat == model.current
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty && !here {
                        Text("Ask anything. ↵ sends, ⇧↵ starts a new line.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in MessageView(message: m).equatable() }
                    if here && model.streaming {
                        MessageView(message: AIMessage(role: .assistant, text: model.reply.isEmpty ? "…" : model.reply), copyable: false)
                    }
                    if here && !model.error.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Label(model.error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                            Button("Try Again") { model.retry() }
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(18)
            }
            .onAppear { proxy.scrollTo("end") }
            .onChange(of: model.current) { proxy.scrollTo("end") }
            .onChange(of: messages.count) { proxy.scrollTo("end") }
            .onChange(of: model.reply) { proxy.scrollTo("end") }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty {
                HStack {
                    ForEach(Array(model.attachments.enumerated()), id: \.offset) { i, data in
                        Thumbnail(data: data, height: 64).equatable()
                            .overlay(alignment: .topTrailing) {
                                Button { model.attachments.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).padding(2)
                            }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                InputView(text: $model.input, focusToken: model.focusToken, onSend: model.send)
                    .frame(height: 70)
                    .overlay(alignment: .topLeading) {
                        if model.input.isEmpty {
                            Text("Ask AI…").foregroundStyle(.tertiary).padding(.leading, 9).padding(.top, 6).allowsHitTesting(false)
                        }
                    }
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                if model.streaming {
                    Button("Stop") { model.stop() }.keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Send") { model.send() }
                        .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty)
                }
            }
        }
        .padding(12)
    }
}

/// Equatable, so typing and streamed chunks do not parse every earlier message again.
private struct MessageView: View, Equatable {
    let message: AIMessage
    var copyable = true

    var body: some View {
        let mine = message.role == .user
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in Thumbnail(data: data, height: 200) }
            if !message.text.isEmpty {
                Text(markdown(message.text))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(mine ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if copyable {
                Button { copyToClipboard(message.text); HUD.show("Copied to Clipboard") } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// An attached PNG; Equatable, so it is decoded again only when the data changes.
private struct Thumbnail: View, Equatable {
    let data: Data
    let height: CGFloat

    var body: some View {
        Image(nsImage: NSImage(data: data) ?? NSImage())
            .resizable().aspectRatio(contentMode: .fit)
            .frame(maxHeight: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The chat input: ↵ sends, ⇧↵ (and ⌥↵) adds a line. An NSTextView, because a SwiftUI field selects all its text
/// when it gets the focus, and the first keystroke would replace a quoted selection.
private struct InputView: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            tv.scrollToEndOfDocument(nil)
        }
        if context.coordinator.focused != focusToken {
            context.coordinator.focused = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }   // the view is in a window only after this update
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputView
        var focused = -1

        init(_ parent: InputView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            parent.text = (notification.object as? NSTextView)?.string ?? ""
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tv.insertNewlineIgnoringFieldEditor(nil) } else { parent.onSend() }
            return true
        }
    }
}

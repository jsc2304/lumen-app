import AppKit
import SwiftUI

/// Borderless panel that takes keyboard focus without activating Lumen, so the app you came from
/// stays frontmost: window commands, paste and selected text all target it.
final class LauncherPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Frosted, rounded background shared by the panel and the HUD.
func blurView(radius r: CGFloat) -> NSVisualEffectView {
    let blur = NSVisualEffectView()
    blur.material = .popover
    blur.blendingMode = .behindWindow
    blur.state = .active
    let mask = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
        NSColor.black.set()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    mask.resizingMode = .stretch
    blur.maskImage = mask
    return blur
}

/// The screen under the mouse; nil only when no display is attached (or all are asleep).
func screenWithMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
}

final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private lazy var panel: LauncherPanel = {
        let p = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 750, height: 474),
                              styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.delegate = self
        p.onKey = { Launcher.shared.handleKey($0) }
        let blur = blurView(radius: 14)
        let host = NSHostingView(rootView: LauncherView(model: .shared))
        host.autoresizingMask = [.width, .height]
        blur.wantsLayer = true   // scaled by popIn
        blur.addSubview(host)
        p.contentView = blur
        host.frame = blur.bounds
        return p
    }()

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    func show(reset: Bool = true) {
        guard let f = screenWithMouse()?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.18 - panel.frame.height))
        if reset { Launcher.shared.reset() }
        let opening = !panel.isVisible
        if opening { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        Launcher.shared.focusToken += 1
        if opening { popIn() }
    }

    func hide() {
        panel.orderOut(nil)
        panel.contentView?.layer?.removeAllAnimations()
        panel.alphaValue = 1
    }

    /// Opening wobble: a fast fade-in and, unless Reduce Motion is on, a scale-up from 96% about the panel's
    /// centre that overshoots slightly. Keys work from the first frame; the animation is only drawn.
    private func popIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 1
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = panel.contentView?.layer else { return }
        let b = layer.bounds, s: CGFloat = 0.96
        // Scale about the centre with a matrix: no anchorPoint change, which AppKit resets on layout.
        let from = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(b.midX, b.midY, 0), s, s, 1), -b.midX, -b.midY, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 1100
        spring.damping = 24
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "popIn")
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

/// A short confirmation at the bottom of the screen ("Copied to Clipboard").
enum HUD {
    private static var window: NSPanel?

    static func show(_ text: String, seconds: Double? = nil) {
        window?.orderOut(nil)
        let host = NSHostingView(rootView: Text(text).font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 10))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let blur = blurView(radius: size.height / 2)
        host.frame = NSRect(origin: .zero, size: size)
        blur.addSubview(host)
        p.contentView = blur
        guard let f = screenWithMouse()?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 90))
        p.orderFrontRegardless()
        window = p
        // Long messages (an error line) stay long enough to read.
        later(seconds ?? (text.count > 30 ? 4 : 1.4)) { if window === p { p.orderOut(nil); window = nil } }
    }
}

struct LauncherView: View {
    @ObservedObject var model: Launcher
    @FocusState private var searchFocused: Bool
    @FocusState private var formFocus: Int?
    @FocusState private var detailDividerFocused: Bool
    @GestureState private var detailDragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                header
                Divider()
                content.frame(maxHeight: .infinity)
                Divider()
                footer
            }
            if model.actionsOpen { actionMenu }
        }
        .onAppear { focus() }
        .onChange(of: model.focusToken) { focus() }
    }

    private func focus() {
        if model.isForm { formFocus = 0 } else { searchFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if !model.isRoot {
                Image(systemName: "chevron.left").foregroundStyle(.secondary).font(.system(size: 15))
            }
            switch model.mode {
            case .root, .list:
                TextField(placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if model.supportsDetail {
                    Spacer(minLength: 0)
                    Button(action: model.toggleDetail) {
                        Image(systemName: "sidebar.right")
                            .foregroundStyle(model.detailVisible ? Color.accentColor : Color.secondary)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .help(model.detailVisible ? "Hide details (⌥⌘I)" : "Show details (⌥⌘I)")
                    .accessibilityLabel(model.detailVisible ? "Hide details" : "Show details")
                }
            default:
                Text(model.title).lineLimit(1)
                Spacer()
            }
        }
        .font(.system(size: 20))
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var placeholder: String {
        if case .list(let spec) = model.mode { return spec.placeholder }
        return "Search apps, files and commands; Tab asks AI…"
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .list(let spec) where spec.showsDetail && model.detailVisible:
            HStack(spacing: 0) {
                resultList.frame(maxWidth: .infinity)
                detailDivider
                detailPane(model.selected?.detail)
                    .frame(width: Launcher.clampDetailWidth(model.detailWidth - detailDragOffset))
            }
        case .root, .list: resultList
        case .form(let spec): form(spec)
        case .answer: answerView
        case .recordHotkey:
            VStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Press the new hotkey").font(.title3)
                Text("Use ⌘, ⌥ or ⌃ with a key · ⌫ removes the hotkey · esc cancels").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { i, item in
                        if !item.section.isEmpty, i == 0 || model.items[i - 1].section != item.section {
                            Text(item.section).font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, i == 0 ? 2 : 8)
                        }
                        Row(item: item, selected: i == model.selection)
                            .id(i)
                            .onTapGesture {
                                model.chooseSelection(i)
                                if let first = item.actions.first { model.perform(first, primary: true) }
                            }
                    }
                }
                .padding(8)
            }
            .onAppear { proxy.scrollTo(model.selection) }
            .onChange(of: model.selection) { proxy.scrollTo(model.selection) }
        }
    }

    private func form(_ spec: FormSpec) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(spec.fields.enumerated()), id: \.offset) { i, field in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(field.label).font(.callout).foregroundStyle(.secondary)
                        if field.multiline {
                            TextEditor(text: value(i))
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .frame(height: 120)
                                .focused($formFocus, equals: i)
                                .modifier(Glass(focused: formFocus == i))
                        } else {
                            TextField(field.placeholder, text: value(i))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .focused($formFocus, equals: i)
                                .modifier(Glass(focused: formFocus == i))
                        }
                    }
                }
                if !model.formError.isEmpty { Text(model.formError).foregroundStyle(.red) }
            }
            .padding(18)
        }
    }

    private func value(_ i: Int) -> Binding<String> {
        Binding(get: { model.formValues.indices.contains(i) ? model.formValues[i] : "" },
                set: { if model.formValues.indices.contains(i) { model.formValues[i] = $0 } })
    }

    private var detailDivider: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(detailDividerFocused ? Color.accentColor : Color.secondary.opacity(0.7))
                .frame(width: 3, height: 26)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .background(detailDividerFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .focusable()
        .focused($detailDividerFocused)
        .onKeyPress(.leftArrow) {
            model.resizeDetail(to: model.detailWidth + 16)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.resizeDetail(to: model.detailWidth - 16)
            return .handled
        }
        .onTapGesture(count: 2) { model.resizeDetail(to: Launcher.defaultDetailWidth) }
        .gesture(
            DragGesture(coordinateSpace: .global)
                .updating($detailDragOffset) { value, offset, _ in offset = value.translation.width }
                .onEnded { value in model.resizeDetail(to: model.detailWidth - value.translation.width) }
        )
        .help("Drag or press ⌥⌘←/→ to resize. When focused, use ←/→. Double-click to reset.")
        .accessibilityLabel("Detail pane width")
        .accessibilityValue("\(Int(model.detailWidth)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.resizeDetail(to: model.detailWidth + 16)
            case .decrement: model.resizeDetail(to: model.detailWidth - 16)
            @unknown default: break
            }
        }
    }

    private func detailPane(_ detail: Detail?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let image = detail?.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 220)
                }
                if let text = detail?.markdown, !text.isEmpty {
                    Text(markdown(text)).textSelection(.enabled)
                }
                if let rows = detail?.metadata, !rows.isEmpty {
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top) {
                            Text(row.0).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.1).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var answerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !model.answer.isEmpty || model.answerError.isEmpty {
                    Text(markdown(model.answer.isEmpty ? "…" : model.answer)).textSelection(.enabled)
                }
                if !model.answerError.isEmpty {
                    Label(model.answerError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    // MARK: Footer and ⌘K menu

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            Spacer()
            if case .form(let spec) = model.mode {
                hint(spec.submitTitle, "⌘↵")
            } else if let primary = model.currentActions.first {
                hint(primary.title, "↵")
                if model.currentActions.count > 1 {
                    Divider().frame(height: 16)
                    hint("Actions", "⌘K")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private var actionMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.filteredActions.enumerated()), id: \.offset) { i, entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.action.icon).frame(width: 18).foregroundStyle(.secondary)
                            Text(entry.action.title).foregroundStyle(entry.action.destructive ? Color.red : Color.primary)
                            Spacer()
                            if let key = shortcutLabel(entry.index, entry.action) {
                                Text(key).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(i == model.actionSelection ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { model.perform(entry.action) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(model.actionQuery.isEmpty ? "Search for actions…" : model.actionQuery)
                .foregroundStyle(model.actionQuery.isEmpty ? .secondary : .primary)
                .padding(.horizontal, 12)
                .frame(height: 36)
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .padding(.trailing, 10)
        .padding(.bottom, 44)
    }

    private func shortcutLabel(_ index: Int, _ action: Action) -> String? {
        if index == 0 { return "↵" }
        if index == 1, !action.general { return "⌘↵" }
        return action.shortcut?.label
    }

    private func hint(_ label: String, _ key: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
            Text(key).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Translucent, softly lit field background for forms; the focused field gets an accent rim.
struct Glass: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return content
            .background(shape.fill(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(focused
                ? AnyShapeStyle(Color.accentColor.opacity(0.9))
                : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom)),
                lineWidth: focused ? 1.5 : 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

struct Row: View {
    let item: Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            Text(item.title).lineLimit(1)
            Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.kind).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item.icon {
        case .image(let image): Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        case .symbol(let name): Image(systemName: name).font(.system(size: 15)).foregroundStyle(.secondary)
        case .color(let color): Circle().fill(Color(nsColor: color)).frame(width: 10, height: 10)
        }
    }
}

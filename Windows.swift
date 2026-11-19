import AppKit

/// Accessibility helpers. All of them act on the frontmost app, which stays frontmost while the
/// launcher panel is open.
enum AX {
    static func promptIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// Never Lumen itself: after an alert or the Settings window Lumen is frontmost, and window commands
    /// and text capture must not act on it.
    private static func frontApp() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// `value` as an element; nil when an app answered with another type, which a force cast would crash on.
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    static func focusedWindow() -> AXUIElement? {
        frontApp().flatMap { element(attribute($0, kAXFocusedWindowAttribute)) }
    }

    static func selectedText() -> String? {
        guard let app = frontApp(), let el = element(attribute(app, kAXFocusedUIElementAttribute)),
              let text = attribute(el, kAXSelectedTextAttribute) as? String, !text.isEmpty else { return nil }
        return text
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        rect(position: attribute(w, kAXPositionAttribute), size: attribute(w, kAXSizeAttribute))
    }

    /// A frame from the position and size values an app reports; nil when either is missing or of another type.
    static func rect(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pos = axValue(position), let dim = axValue(size),
              AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(dim, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        guard let pos = AXValueCreate(.cgPoint, &p), let size = AXValueCreate(.cgSize, &s) else { return }
        // Apps with AXEnhancedUserInterface on (Chrome, Electron, Safari while any assistive tool runs) animate
        // every frame change and drop the next ones mid-animation, so a command needed several presses.
        // Off for the move, then back, as Rectangle does.
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        let app = AXUIElementCreateApplication(pid)
        let enhanced = flag(app, "AXEnhancedUserInterface")
        if enhanced { set(app, "AXEnhancedUserInterface", false) }
        defer { if enhanced { set(app, "AXEnhancedUserInterface", true) } }
        // Size, position, size again: a window moving to another display is otherwise clamped by the old one.
        // One more pass when the window did not land where asked (some apps apply the first set late).
        for _ in 0..<2 {
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, size)
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, size)
            guard let now = frame(w), abs(now.minX - r.minX) >= 2 || abs(now.minY - r.minY) >= 2
                    || abs(now.width - r.width) >= 2 || abs(now.height - r.height) >= 2 else { return }
        }
    }

    /// Sends a key press (virtual key code) with modifiers to the frontmost app.
    static func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        guard promptIfNeeded() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// The frontmost app's standard windows that are not minimized.
    static func windows() -> [AXUIElement] {
        guard let app = frontApp(), let all = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return all.filter { attribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole && !flag($0, kAXMinimizedAttribute) }
    }

    /// Standard windows of every other app that are on screen in the current Space (not minimized, not hidden,
    /// not on another Space): the window server's on-screen list, matched to Accessibility windows by frame.
    static func visibleWindows() -> [AXUIElement] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var onScreen: [pid_t: [CGRect]] = [:]
        for w in info where w[kCGWindowLayer as String] as? Int == 0 && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            onScreen[pid, default: []].append(bounds)
        }
        return onScreen.flatMap { pid, frames -> [AXUIElement] in
            guard let all = attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
            return all.filter { w in
                guard attribute(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole, !flag(w, kAXMinimizedAttribute),
                      let f = frame(w) else { return false }
                return frames.contains { abs($0.minX - f.minX) < 2 && abs($0.minY - f.minY) < 2 && abs($0.width - f.width) < 2 }
            }
        }
    }

    static func flag(_ w: AXUIElement, _ name: String) -> Bool { attribute(w, name) as? Bool ?? false }

    @discardableResult
    static func set(_ w: AXUIElement, _ name: String, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(w, name as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    static func raise(_ w: AXUIElement) {
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        set(w, kAXMainAttribute, true)
    }

    /// Stays the same for the lifetime of the window, even when its title changes.
    static func identity(_ w: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        return "\(pid):\(CFHash(w))"
    }
}

/// The frame a window had before Lumen last changed it, per window. Plain bookkeeping, checked in checks/.
struct FrameHistory {
    static let capacity = 100
    private var entries: [(key: String, frame: CGRect)] = []   // oldest first

    /// Remembers `before` as the frame to restore, unless the change moves nothing.
    mutating func record(_ key: String, before: CGRect, after: CGRect) {
        guard !Self.same(before, after) else { return }
        entries.removeAll { $0.key == key }
        entries.append((key, before))
        if entries.count > Self.capacity { entries.removeFirst() }
    }

    /// Takes the remembered frame and keeps `current` in its place, so a second restore undoes the first.
    mutating func restore(_ key: String, current: CGRect) -> CGRect? {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let previous = entries[i].frame
        entries[i].frame = current
        return previous
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        [a.minX - b.minX, a.minY - b.minY, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 1 }
    }
}

enum WindowCommands {
    struct Layout {
        let name: String
        let symbol: String
        var keywords: [String] = []
        let frame: (_ screen: CGRect, _ window: CGRect) -> CGRect
    }

    /// A display's whole area and its usable area (without menu bar and Dock), in Accessibility
    /// coordinates: origin at the top left of the primary display, y pointing down.
    struct Display {
        let full: CGRect
        let visible: CGRect
    }

    // MARK: Layouts

    /// A rectangle given as fractions of the screen.
    private static func part(_ name: String, _ symbol: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Layout {
        Layout(name: name, symbol: symbol) { s, _ in
            CGRect(x: s.minX + s.width * x, y: s.minY + s.height * y, width: s.width * w, height: s.height * h)
        }
    }

    // Frames in Accessibility coordinates, on the window's current screen.
    static let layouts: [Layout] = [
        part("Left Half", "rectangle.lefthalf.filled", 0, 0, 1/2, 1),
        part("Right Half", "rectangle.righthalf.filled", 1/2, 0, 1/2, 1),
        part("Top Half", "rectangle.tophalf.filled", 0, 0, 1, 1/2),
        part("Bottom Half", "rectangle.bottomhalf.filled", 0, 1/2, 1, 1/2),
        part("Center Half", "rectangle.center.inset.filled", 1/4, 0, 1/2, 1),
        Layout(name: "Cycle Left", symbol: "rectangle.leftthird.inset.filled", keywords: cycleKeywords) { s, w in
            cycledSide(s, w, left: true) },
        Layout(name: "Cycle Right", symbol: "rectangle.rightthird.inset.filled", keywords: cycleKeywords) { s, w in
            cycledSide(s, w, left: false) },

        part("First Third", "rectangle.leftthird.inset.filled", 0, 0, 1/3, 1),
        part("Center Third", "rectangle.split.3x1", 1/3, 0, 1/3, 1),
        part("Last Third", "rectangle.rightthird.inset.filled", 2/3, 0, 1/3, 1),
        part("First Two Thirds", "rectangle.split.3x1", 0, 0, 2/3, 1),
        part("Center Two Thirds", "rectangle.split.3x1", 1/6, 0, 2/3, 1),
        part("Last Two Thirds", "rectangle.split.3x1", 1/3, 0, 2/3, 1),
        part("First Three Fourths", "rectangle.lefthalf.inset.filled", 0, 0, 3/4, 1),
        part("Center Three Fourths", "rectangle.center.inset.filled", 1/8, 0, 3/4, 1),
        part("Last Three Fourths", "rectangle.righthalf.inset.filled", 1/4, 0, 3/4, 1),
        part("First Fourth", "rectangle.split.3x1", 0, 0, 1/4, 1),
        part("Second Fourth", "rectangle.split.3x1", 1/4, 0, 1/4, 1),
        part("Third Fourth", "rectangle.split.3x1", 1/2, 0, 1/4, 1),
        part("Last Fourth", "rectangle.split.3x1", 3/4, 0, 1/4, 1),

        part("Top Third", "rectangle.topthird.inset.filled", 0, 0, 1, 1/3),
        part("Middle Third", "rectangle.center.inset.filled", 0, 1/3, 1, 1/3),
        part("Bottom Third", "rectangle.bottomthird.inset.filled", 0, 2/3, 1, 1/3),
        part("Top Two Thirds", "rectangle.tophalf.inset.filled", 0, 0, 1, 2/3),
        part("Bottom Two Thirds", "rectangle.bottomhalf.inset.filled", 0, 1/3, 1, 2/3),
        part("Top Three Fourths", "rectangle.tophalf.inset.filled", 0, 0, 1, 3/4),
        part("Bottom Three Fourths", "rectangle.bottomhalf.inset.filled", 0, 1/4, 1, 3/4),

        part("Top Left Quarter", "rectangle.inset.topleft.filled", 0, 0, 1/2, 1/2),
        part("Top Right Quarter", "rectangle.inset.topright.filled", 1/2, 0, 1/2, 1/2),
        part("Bottom Left Quarter", "rectangle.inset.bottomleft.filled", 0, 1/2, 1/2, 1/2),
        part("Bottom Right Quarter", "rectangle.inset.bottomright.filled", 1/2, 1/2, 1/2, 1/2),

        part("Top Left Sixth", "rectangle.grid.3x2", 0, 0, 1/3, 1/2),
        part("Top Center Sixth", "rectangle.grid.3x2", 1/3, 0, 1/3, 1/2),
        part("Top Right Sixth", "rectangle.grid.3x2", 2/3, 0, 1/3, 1/2),
        part("Bottom Left Sixth", "rectangle.grid.3x2", 0, 1/2, 1/3, 1/2),
        part("Bottom Center Sixth", "rectangle.grid.3x2", 1/3, 1/2, 1/3, 1/2),
        part("Bottom Right Sixth", "rectangle.grid.3x2", 2/3, 1/2, 1/3, 1/2),

        Layout(name: "Maximize", symbol: "arrow.up.left.and.arrow.down.right", keywords: ["full"]) { s, _ in s },
        Layout(name: "Maximize Height", symbol: "arrow.up.and.down") { s, w in
            CGRect(x: w.minX, y: s.minY, width: w.width, height: s.height) },
        Layout(name: "Maximize Width", symbol: "arrow.left.and.right") { s, w in
            CGRect(x: s.minX, y: w.minY, width: s.width, height: w.height) },
        Layout(name: "Almost Maximize", symbol: "macwindow") { s, _ in s.insetBy(dx: s.width * 0.05, dy: s.height * 0.05) },
        Layout(name: "Reasonable Size", symbol: "rectangle.inset.filled", keywords: ["default size"]) { s, _ in
            centered(CGSize(width: s.width * 0.6, height: s.height * 0.75), in: s) },
        Layout(name: "Center", symbol: "align.horizontal.center", keywords: ["zentrieren", "middle"]) { s, w in centered(w.size, in: s) },

        Layout(name: "Make Smaller", symbol: "minus.rectangle", keywords: ["shrink", "verkleinern"]) { s, w in resized(w, in: s, by: -0.1) },
        Layout(name: "Make Larger", symbol: "plus.rectangle", keywords: ["grow", "enlarge", "vergrößern"]) { s, w in resized(w, in: s, by: 0.1) },

        Layout(name: "Move Left", symbol: "arrow.left.to.line") { s, w in CGRect(origin: CGPoint(x: s.minX, y: w.minY), size: w.size) },
        Layout(name: "Move Right", symbol: "arrow.right.to.line") { s, w in
            CGRect(origin: CGPoint(x: max(s.minX, s.maxX - w.width), y: w.minY), size: w.size) },
        Layout(name: "Move Top", symbol: "arrow.up.to.line", keywords: ["move up"]) { s, w in
            CGRect(origin: CGPoint(x: w.minX, y: s.minY), size: w.size) },
        Layout(name: "Move Bottom", symbol: "arrow.down.to.line", keywords: ["move down"]) { s, w in
            CGRect(origin: CGPoint(x: w.minX, y: max(s.minY, s.maxY - w.height)), size: w.size) },
    ]

    // MARK: Commands

    private static let german = [
        "left": "links", "right": "rechts", "top": "oben", "bottom": "unten", "center": "mitte", "middle": "mitte",
        "half": "hälfte", "third": "drittel", "thirds": "drittel", "fourth": "viertel", "fourths": "viertel",
        "quarter": "viertel", "sixth": "sechstel", "first": "erste", "last": "letzte", "maximize": "maximieren",
        "move": "verschieben",
    ]

    /// "window" and "fenster", the title's words in German, then `extra`.
    static func keywords(_ title: String, _ extra: [String] = []) -> [String] {
        var seen = Set<String>()
        let translated = title.lowercased().split(separator: " ").compactMap { german[String($0)] }
        return (["window", "fenster"] + translated + extra).filter { seen.insert($0).inserted }
    }

    private static func command(_ id: String, _ title: String, _ icon: String, _ extra: [String] = [],
                                run: @escaping () -> Void) -> Item {
        .command(id, title, kind: "Window", icon: icon, keywords: keywords(title, extra), run: run)
    }

    static func items() -> [Item] {
        layouts.map { l in command("win." + l.name, l.name, l.symbol, l.keywords) { apply(l.frame) } } + [
            command("win.restore", "Restore", "arrow.uturn.backward", ["undo", "back", "previous size", "zurück", "wiederherstellen"]) { restore() },
            command("win.previous-display", "Previous Display", "display.2",
                    ["move to previous display", "monitor", "screen", "bildschirm"]) { moveToDisplay(by: -1) },
            command("win.next-display", "Next Display", "display.2",
                    ["move to next display", "monitor", "screen", "bildschirm"]) { moveToDisplay(by: 1) },
            command("win.minimize", "Minimize", "dock.arrow.down.rectangle", ["minimieren"]) { minimize() },
            command("win.fullscreen", "Toggle Fullscreen", "rectangle.arrowtriangle.2.outward",
                    ["fullscreen", "full screen", "vollbild"]) { toggleFullscreen() },
            // ⌃← / ⌃→ are the Mission Control shortcuts; they have to be enabled in System Settings.
            command("win.previous-space", "Switch to Previous Space", "chevron.left.2", ["space", "desktop"]) {
                later { AX.key(123, [.maskControl, .maskSecondaryFn]) } },
            command("win.next-space", "Switch to Next Space", "chevron.right.2", ["space", "desktop"]) {
                later { AX.key(124, [.maskControl, .maskSecondaryFn]) } },
            command("win.focus-previous", "Focus Previous App Window", "macwindow.on.rectangle", ["switch", "cycle", "wechseln"]) { focusWindow(by: -1) },
            command("win.tile", "Tile Visible Windows", "rectangle.split.3x1",
                    ["split", "columns", "side by side", "aufteilen", "nebeneinander", "spalten", "alle"]) { tileVisible() },
            command("win.focus-next", "Focus Next App Window", "macwindow.on.rectangle", ["switch", "cycle", "wechseln"]) { focusWindow(by: 1) },
        ]
    }

    // MARK: Geometry (pure)

    /// "Tile Visible Windows" stops above this many windows: narrower columns are no longer usable.
    static let maxTiles = 6

    /// `count` full-height columns side by side, edges rounded once so neighbours share them exactly.
    static func columns(_ count: Int, in s: CGRect) -> [CGRect] {
        func edge(_ i: Int) -> CGFloat { (s.minX + s.width * CGFloat(i) / CGFloat(count)).rounded() }
        let y0 = s.minY.rounded(), y1 = s.maxY.rounded()
        return (0..<count).map { CGRect(x: edge($0), y: y0, width: edge($0 + 1) - edge($0), height: y1 - y0) }
    }

    /// The widths "Cycle Left" and "Cycle Right" step through, as fractions of the screen.
    static let cycleFractions: [CGFloat] = [1/2, 1/3, 1/4]
    private static let cycleKeywords = ["toggle", "half", "third", "fourth", "hälfte", "drittel", "viertel", "wechseln"]

    /// A full-height tile at the left (or right) edge. If the window already is one of the cycle's tiles
    /// on that side, the next narrower one, after the narrowest the half again; otherwise the half.
    /// Matching allows some slack, because apps like Terminal round their size to whole cells.
    static func cycledSide(_ s: CGRect, _ w: CGRect, left: Bool) -> CGRect {
        let slack: CGFloat = 20
        let atEdge = left ? abs(w.minX - s.minX) <= slack : abs(w.maxX - s.maxX) <= slack
        let fullHeight = abs(w.minY - s.minY) <= slack && abs(w.height - s.height) <= slack
        let current = atEdge && fullHeight ? cycleFractions.firstIndex { abs(w.width - s.width * $0) <= slack } : nil
        let width = s.width * cycleFractions[current.map { ($0 + 1) % cycleFractions.count } ?? 0]
        return CGRect(x: left ? s.minX : s.maxX - width, y: s.minY, width: width, height: s.height)
    }

    /// Rounds each edge, so neighbouring tiles share an edge exactly.
    static func snapped(_ r: CGRect) -> CGRect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded()
        return CGRect(x: x0, y: y0, width: r.maxX.rounded() - x0, height: r.maxY.rounded() - y0)
    }

    static func centered(_ size: CGSize, in s: CGRect) -> CGRect {
        CGRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Moves and shrinks `r` until it fits into `s`.
    static func clamped(_ r: CGRect, in s: CGRect) -> CGRect {
        let w = min(r.width, s.width), h = min(r.height, s.height)
        return CGRect(x: min(max(r.minX, s.minX), s.maxX - w), y: min(max(r.minY, s.minY), s.maxY - h), width: w, height: h)
    }

    /// Grows (or, with a negative `step`, shrinks) around the window's center by `step` of the screen
    /// size. Smaller stops at a fifth of the screen, or at the window's own size if that is already less.
    static func resized(_ w: CGRect, in s: CGRect, by step: CGFloat) -> CGRect {
        let width = min(max(w.width + step * s.width, min(w.width, s.width / 5)), s.width)
        let height = min(max(w.height + step * s.height, min(w.height, s.height / 5)), s.height)
        return clamped(CGRect(x: w.midX - width / 2, y: w.midY - height / 2, width: width, height: height), in: s)
    }

    /// The same relative position and size on another display.
    static func mapped(_ f: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        let sx = b.width / a.width, sy = b.height / a.height
        return clamped(CGRect(x: b.minX + (f.minX - a.minX) * sx, y: b.minY + (f.minY - a.minY) * sy,
                              width: f.width * sx, height: f.height * sy), in: b)
    }

    /// A Cocoa rectangle (origin bottom left of the primary display) in Accessibility coordinates.
    static func axRect(_ r: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    /// Left to right, then top to bottom: the order "next" and "previous" display follow.
    static func ordered(_ displays: [Display]) -> [Display] {
        displays.sorted { ($0.full.minX, $0.full.minY) < ($1.full.minX, $1.full.minY) }
    }

    /// The display that holds the window's center, or else the one it overlaps most.
    static func display(containing window: CGRect, in displays: [Display]) -> Int {
        let center = CGPoint(x: window.midX, y: window.midY)
        if let i = displays.firstIndex(where: { $0.full.contains(center) }) { return i }
        func overlap(_ d: Display) -> CGFloat {
            let i = d.full.intersection(window)
            return i.isNull ? 0 : i.width * i.height
        }
        return displays.indices.max { overlap(displays[$0]) < overlap(displays[$1]) } ?? 0
    }

    /// `index` moved by `step` around a ring of `count`; without an index, the first (or last) entry.
    static func cycled(_ index: Int?, count: Int, by step: Int) -> Int {
        guard let index else { return step > 0 ? 0 : count - 1 }
        return ((index + step) % count + count) % count
    }

    /// A stable order to cycle windows in: left to right, top to bottom, then by identity. The
    /// system's own order changes with every raise, which would only ever toggle two windows.
    static func cycleOrder(_ windows: [(frame: CGRect, id: UInt)]) -> [Int] {
        func key(_ i: Int) -> (CGFloat, CGFloat, UInt) { (windows[i].frame.minX, windows[i].frame.minY, windows[i].id) }
        return windows.indices.sorted { key($0) < key($1) }
    }

    // MARK: Acting on the focused window

    private static var history = FrameHistory()

    private struct Target {
        let window: AXUIElement
        let frame: CGRect
        let displays: [Display]
        let index: Int
        var display: Display { displays[index] }
    }

    private static func displays() -> [Display] {
        guard let primary = NSScreen.screens.first?.frame else { return [] }
        return ordered(NSScreen.screens.map {
            Display(full: axRect($0.frame, primaryMaxY: primary.maxY), visible: axRect($0.visibleFrame, primaryMaxY: primary.maxY))
        })
    }

    private static func focused() -> Target? {
        let all = displays()
        guard AX.promptIfNeeded(), !all.isEmpty, let w = AX.focusedWindow(), let f = AX.frame(w) else { NSSound.beep(); return nil }
        return Target(window: w, frame: f, displays: all, index: display(containing: f, in: all))
    }

    private static func place(_ t: Target, _ r: CGRect) {
        let target = snapped(r)
        history.record(AX.identity(t.window), before: t.frame, after: target)
        AX.setFrame(t.window, target)
    }

    static func apply(_ layout: (CGRect, CGRect) -> CGRect) {
        guard let t = focused() else { return }
        place(t, layout(t.display.visible, t.frame))
    }

    private static func restore() {
        guard let t = focused() else { return }
        guard let previous = history.restore(AX.identity(t.window), current: t.frame) else { HUD.show("Nothing to Restore"); return }
        AX.setFrame(t.window, previous)
    }

    private static func moveToDisplay(by step: Int) {
        guard let t = focused() else { return }
        guard t.displays.count > 1 else { HUD.show("No Other Display"); return }
        let to = t.displays[cycled(t.index, count: t.displays.count, by: step)]
        place(t, mapped(t.frame, from: t.display.visible, to: to.visible))
    }

    private static func minimize() {
        guard let t = focused() else { return }
        if !AX.set(t.window, kAXMinimizedAttribute, true) { NSSound.beep() }
    }

    private static func toggleFullscreen() {
        guard let t = focused() else { return }
        if !AX.set(t.window, "AXFullScreen", !AX.flag(t.window, "AXFullScreen")) { NSSound.beep() }
    }

    /// The visible windows on the focused window's display, as columns in their current left-to-right order.
    private static func tileVisible() {
        guard let t = focused() else { return }
        let framed = AX.visibleWindows().compactMap { w in AX.frame(w).map { (window: w, frame: $0) } }
            .filter { display(containing: $0.frame, in: t.displays) == t.index }
        guard framed.count > 1 else { HUD.show("No Other Window"); return }
        guard framed.count <= maxTiles else { HUD.show("\(framed.count) Windows, at Most \(maxTiles)"); return }
        let order = cycleOrder(framed.map { ($0.frame, CFHash($0.window)) })
        for (column, i) in zip(columns(order.count, in: t.display.visible), order) {
            history.record(AX.identity(framed[i].window), before: framed[i].frame, after: column)
            AX.setFrame(framed[i].window, column)
        }
        AX.raise(t.window)
    }

    private static func focusWindow(by step: Int) {
        guard AX.promptIfNeeded() else { NSSound.beep(); return }
        let framed = AX.windows().compactMap { w in AX.frame(w).map { (window: w, frame: $0) } }
        guard !framed.isEmpty else { NSSound.beep(); return }
        guard framed.count > 1 else { HUD.show("No Other Window"); return }
        let windows = cycleOrder(framed.map { ($0.frame, CFHash($0.window)) }).map { framed[$0].window }
        let current = AX.focusedWindow().flatMap { f in windows.firstIndex { CFEqual($0, f) } }
        AX.raise(windows[cycled(current, count: windows.count, by: step)])
    }
}

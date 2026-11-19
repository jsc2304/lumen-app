import AppKit

func checkWindows() {
    typealias W = WindowCommands

    // Two displays in Accessibility coordinates: a laptop screen (menu bar on top, Dock at the bottom)
    // with odd sizes, so rounding shows, and a larger one to its left and above.
    let a = CGRect(x: 0, y: 25, width: 1441, height: 781)
    let b = CGRect(x: -1920, y: -300, width: 1920, height: 1055)
    let win = CGRect(x: 100, y: 80, width: 700, height: 500)

    func layout(_ name: String) -> W.Layout { W.layouts.first { $0.name == name }! }
    func tile(_ name: String, _ s: CGRect, _ w: CGRect = win) -> CGRect { W.snapped(layout(name).frame(s, w)) }

    for s in [a, b] {
        // Every layout yields a non-empty frame inside the screen.
        for l in W.layouts {
            let f = W.snapped(l.frame(s, win.offsetBy(dx: s.minX, dy: s.minY)))
            expect(f.width > 0 && f.height > 0 && s.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(l.name) stays on screen")
        }

        // Halves, quarters, thirds, fourths and sixths tile the screen without gaps or overlaps.
        let l = tile("Left Half", s), r = tile("Right Half", s), t = tile("Top Half", s), bt = tile("Bottom Half", s)
        expect(l.minX == s.minX && l.maxX == r.minX && r.maxX == s.maxX && l.height == s.height, "halves tile")
        expect(t.minY == s.minY && t.maxY == bt.minY && bt.maxY == s.maxY && t.width == s.width, "top/bottom halves tile")
        let ch = tile("Center Half", s)
        expect(abs(ch.midX - s.midX) <= 0.5 && abs(ch.width - s.width / 2) <= 1 && ch.height == s.height, "center half")

        let th = ["First Third", "Center Third", "Last Third"].map { tile($0, s) }
        expect(th[0].minX == s.minX && th[0].maxX == th[1].minX && th[1].maxX == th[2].minX && th[2].maxX == s.maxX, "thirds tile")
        let fo = ["First Fourth", "Second Fourth", "Third Fourth", "Last Fourth"].map { tile($0, s) }
        expect(fo[0].minX == s.minX && fo[0].maxX == fo[1].minX && fo[1].maxX == fo[2].minX && fo[2].maxX == fo[3].minX
               && fo[3].maxX == s.maxX, "fourths tile")
        let vt = ["Top Third", "Middle Third", "Bottom Third"].map { tile($0, s) }
        expect(vt[0].minY == s.minY && vt[0].maxY == vt[1].minY && vt[1].maxY == vt[2].minY && vt[2].maxY == s.maxY, "vertical thirds tile")

        let q = ["Top Left Quarter", "Top Right Quarter", "Bottom Left Quarter", "Bottom Right Quarter"].map { tile($0, s) }
        expect(q[0].maxX == q[1].minX && q[2].maxX == q[3].minX && q[0].maxY == q[2].minY && q[1].maxY == q[3].minY, "quarters meet")
        expect(q[0].origin == s.origin && q[3].maxX == s.maxX && q[3].maxY == s.maxY, "quarters cover the corners")

        let six = ["Top Left Sixth", "Top Center Sixth", "Top Right Sixth", "Bottom Left Sixth", "Bottom Center Sixth", "Bottom Right Sixth"]
            .map { tile($0, s) }
        expect(six[0].maxX == six[1].minX && six[1].maxX == six[2].minX && six[2].maxX == s.maxX, "top sixths tile")
        expect(six[3].maxX == six[4].minX && six[4].maxX == six[5].minX && six[0].maxY == six[3].minY, "bottom sixths tile")

        // Two and three of the fractions: edges line up with the matching thirds and fourths.
        expect(tile("First Two Thirds", s).maxX == th[1].maxX && tile("Last Two Thirds", s).minX == th[1].minX, "two thirds")
        let c23 = tile("Center Two Thirds", s)
        expect(abs(c23.midX - s.midX) <= 1 && abs(c23.width - s.width * 2 / 3) <= 1, "center two thirds")
        expect(tile("First Three Fourths", s).maxX == fo[2].maxX && tile("Last Three Fourths", s).minX == fo[0].maxX, "three fourths")
        expect(tile("Top Two Thirds", s).maxY == vt[1].maxY && tile("Bottom Two Thirds", s).minY == vt[0].maxY, "vertical two thirds")
        expect(tile("Top Three Fourths", s).height == (s.height * 3 / 4).rounded() && tile("Bottom Three Fourths", s).maxY == s.maxY, "vertical three fourths")
    }

    // Cycle Left / Cycle Right: half, third, fourth, half again; anything else starts at the half.
    for s in [a, b] {
        for (name, other) in [("Cycle Left", "Left Half"), ("Cycle Right", "Right Half")] {
            var f = tile(name, s, win.offsetBy(dx: s.minX, dy: s.minY))
            expect(f == tile(other, s), "\(name) starts with the half")
            let left = name == "Cycle Left"
            let third = tile(left ? "First Third" : "Last Third", s), fourth = tile(left ? "First Fourth" : "Last Fourth", s)
            f = tile(name, s, f); expect(f == third, "\(name) then the third")
            f = tile(name, s, f); expect(f == fourth, "\(name) then the fourth")
            f = tile(name, s, f); expect(f == tile(other, s), "\(name) wraps to the half")
            // A Terminal-like window a few pixels short of the third still counts as the third.
            let rough = CGRect(x: left ? third.minX : third.minX + 7, y: third.minY, width: third.width - 7, height: third.height - 12)
            expect(tile(name, s, rough) == fourth, "\(name) tolerates cell rounding")
            // The same width on the other side starts over.
            let opposite = tile(left ? "Last Third" : "First Third", s)
            expect(tile(name, s, opposite) == tile(other, s), "\(name) ignores the other side")
        }
    }

    // Exact values on a screen where nothing rounds.
    let e = CGRect(x: 10, y: 20, width: 1200, height: 800)
    expect(tile("Left Half", e) == CGRect(x: 10, y: 20, width: 600, height: 800), "left half frame")
    expect(tile("Last Two Thirds", e) == CGRect(x: 410, y: 20, width: 800, height: 800), "last two thirds frame")
    expect(tile("Third Fourth", e) == CGRect(x: 610, y: 20, width: 300, height: 800), "third fourth frame")
    expect(tile("Bottom Right Sixth", e) == CGRect(x: 810, y: 420, width: 400, height: 400), "bottom right sixth frame")
    expect(tile("Maximize", e) == e, "maximize")
    expect(tile("Almost Maximize", e) == CGRect(x: 70, y: 60, width: 1080, height: 720), "almost maximize")

    // Window-dependent layouts keep what they do not change.
    expect(tile("Maximize Height", e) == CGRect(x: 100, y: 20, width: 700, height: 800), "maximize height")
    expect(tile("Maximize Width", e) == CGRect(x: 10, y: 80, width: 1200, height: 500), "maximize width")
    expect(tile("Center", e) == CGRect(x: 260, y: 170, width: 700, height: 500), "center keeps the size")
    expect(tile("Reasonable Size", e) == CGRect(x: 250, y: 120, width: 720, height: 600), "reasonable size is 60% x 75%, centered")
    expect(tile("Move Left", e) == CGRect(x: 10, y: 80, width: 700, height: 500), "move left")
    expect(tile("Move Right", e) == CGRect(x: 510, y: 80, width: 700, height: 500), "move right")
    expect(tile("Move Top", e) == CGRect(x: 100, y: 20, width: 700, height: 500), "move top")
    expect(tile("Move Bottom", e) == CGRect(x: 100, y: 320, width: 700, height: 500), "move bottom")
    let huge = CGRect(x: 0, y: 0, width: 2000, height: 1000)
    expect(tile("Move Right", e, huge).minX == e.minX && tile("Move Bottom", e, huge).minY == e.minY, "moving a window larger than the screen stays at the origin")

    // Make larger / smaller: 10% of the screen per step, around the center, never off screen.
    let bigger = W.resized(win, in: e, by: 0.1)
    expect(bigger == CGRect(x: 40, y: 40, width: 820, height: 580), "larger grows by 10% of the screen around the center")
    expect(W.resized(bigger, in: e, by: -0.1) == win, "smaller undoes larger")
    let nearEdge = W.resized(CGRect(x: 700, y: 100, width: 500, height: 400), in: e, by: 0.1)
    expect(nearEdge.width == 620 && nearEdge.maxX == e.maxX, "larger near the edge is pulled back in")
    expect(W.resized(CGRect(x: 10, y: 20, width: 1100, height: 700), in: e, by: 0.5) == e, "larger stops at the screen")
    let floor = W.resized(CGRect(x: 400, y: 300, width: 300, height: 200), in: e, by: -0.1)
    expect(floor.width == 240 && floor.height == 160, "smaller stops at a fifth of the screen")
    let tiny = CGRect(x: 400, y: 300, width: 100, height: 100)
    expect(W.resized(tiny, in: e, by: -0.1).size == tiny.size, "smaller never grows a small window")
    expect(W.resized(CGRect(x: 0, y: 0, width: 3000, height: 2000), in: e, by: -0.1) == e, "an oversized window shrinks to the screen")

    // Displays.
    let primaryMaxY: CGFloat = 900
    expect(W.axRect(CGRect(x: 0, y: 95, width: 1440, height: 780), primaryMaxY: primaryMaxY) == CGRect(x: 0, y: 25, width: 1440, height: 780),
           "usable area of the primary display")
    expect(W.axRect(CGRect(x: 0, y: 900, width: 1920, height: 1080), primaryMaxY: primaryMaxY).minY == -1080, "a display above the primary has negative y")

    let da = W.Display(full: CGRect(x: 0, y: 0, width: 1440, height: 806), visible: a)
    let db = W.Display(full: CGRect(x: -1920, y: -300, width: 1920, height: 1080), visible: b)
    let dc = W.Display(full: CGRect(x: 1440, y: 0, width: 1000, height: 800), visible: CGRect(x: 1440, y: 0, width: 1000, height: 800))
    expect(W.ordered([dc, da, db]).map(\.full) == [db.full, da.full, dc.full], "displays are ordered left to right")
    expect(W.ordered([da, W.Display(full: CGRect(x: 0, y: -900, width: 1440, height: 900), visible: a)]).first!.full.minY == -900, "equal x: top first")

    let all = [db, da, dc]
    expect(W.display(containing: CGRect(x: 100, y: 100, width: 400, height: 300), in: all) == 1, "window on the laptop screen")
    expect(W.display(containing: CGRect(x: -1500, y: 0, width: 400, height: 300), in: all) == 0, "window on the left display")
    expect(W.display(containing: CGRect(x: 1400, y: 100, width: 600, height: 300), in: all) == 2, "center decides")
    expect(W.display(containing: CGRect(x: 0, y: 5000, width: 100, height: 100), in: all) == 0, "far away falls back to the first display")
    expect(W.display(containing: CGRect(x: 1300, y: 790, width: 300, height: 300), in: [da, dc]) == 0, "no center hit: largest overlap")

    expect(W.cycled(0, count: 3, by: -1) == 2 && W.cycled(2, count: 3, by: 1) == 0 && W.cycled(1, count: 3, by: 1) == 2, "cycling wraps")
    expect(W.cycled(0, count: 1, by: 1) == 0 && W.cycled(nil, count: 4, by: 1) == 0 && W.cycled(nil, count: 4, by: -1) == 3, "cycling without a current entry")

    // Moving to another display keeps the relative position and the size ratio.
    let src = CGRect(x: 0, y: 0, width: 1000, height: 500), dst = CGRect(x: 2000, y: 100, width: 2000, height: 1000)
    expect(W.mapped(CGRect(x: 250, y: 100, width: 500, height: 250), from: src, to: dst) == CGRect(x: 2500, y: 300, width: 1000, height: 500),
           "relative frame is scaled to the other display")
    expect(W.mapped(CGRect(x: 0, y: 0, width: 1000, height: 500), from: src, to: dst) == dst, "a maximized window stays maximized")
    expect(W.mapped(CGRect(x: 900, y: 450, width: 300, height: 100), from: src, to: dst).maxX == dst.maxX, "mapped frame is pulled back onto the display")
    expect(W.mapped(win, from: a, to: a) == win, "same display is the identity")

    // Cycling windows.
    let order = W.cycleOrder([(CGRect(x: 500, y: 0, width: 1, height: 1), 3), (CGRect(x: 0, y: 200, width: 1, height: 1), 9),
                              (CGRect(x: 0, y: 100, width: 1, height: 1), 7), (CGRect(x: 0, y: 100, width: 1, height: 1), 5)])
    expect(order == [3, 2, 1, 0], "cycle order: x, then y, then identity")

    // Restore bookkeeping.
    var h = FrameHistory()
    let f1 = CGRect(x: 0, y: 0, width: 400, height: 300), f2 = CGRect(x: 50, y: 50, width: 800, height: 600), f3 = CGRect(x: 90, y: 90, width: 100, height: 100)
    expect(h.restore("w", current: f1) == nil, "nothing to restore at first")
    h.record("w", before: f1, after: f2)
    h.record("other", before: f3, after: f2)
    expect(h.restore("w", current: f2) == f1, "restore returns the frame before the change")
    expect(h.restore("w", current: f1) == f2, "a second restore undoes the first")
    expect(h.restore("other", current: f2) == f3, "windows are kept apart")
    h.record("w", before: f2, after: f3)
    h.record("w", before: f3, after: f3.offsetBy(dx: 0.4, dy: -0.4))
    expect(h.restore("w", current: f3) == f2, "a change that moves nothing keeps the older frame")
    h.record("w", before: f1, after: f2)
    h.record("w", before: f3, after: f1)
    expect(h.restore("w", current: f1) == f3, "only the last change is remembered")
    var many = FrameHistory()
    for i in 0...FrameHistory.capacity { many.record("w\(i)", before: f1, after: f2) }
    expect(many.restore("w0", current: f2) == nil && many.restore("w1", current: f2) == f1, "the oldest entry is dropped at capacity")

    // Values from other apps: the wrong type is refused instead of crashing a force cast.
    var point = CGPoint(x: 10, y: 20), dim = CGSize(width: 300, height: 200)
    let pointValue = AXValueCreate(.cgPoint, &point)!, sizeValue = AXValueCreate(.cgSize, &dim)!
    expect(AX.rect(position: pointValue, size: sizeValue) == CGRect(x: 10, y: 20, width: 300, height: 200), "frame from AXValues")
    expect(AX.rect(position: "10,20" as CFString, size: sizeValue) == nil && AX.rect(position: pointValue, size: nil) == nil,
           "a frame needs two AXValues")
    expect(AX.rect(position: sizeValue, size: pointValue) == nil, "an AXValue of the wrong kind is no frame")
    expect(AX.element(AXUIElementCreateSystemWide()) != nil, "an element is an element")
    expect(AX.element("window" as CFString) == nil && AX.element(pointValue) == nil && AX.element(nil) == nil, "other types are no element")

    // Commands.
    let items = W.items()
    let ids = items.map(\.id)
    expect(Set(ids).count == ids.count, "command ids are unique")
    for id in ["win.Left Half", "win.Right Half", "win.Top Half", "win.Bottom Half", "win.Maximize", "win.Almost Maximize", "win.Center",
               "win.First Third", "win.Center Third", "win.Last Third", "win.First Two Thirds", "win.Last Two Thirds", "win.next-display"] {
        expect(ids.contains(id), "existing id \(id) is kept")
    }
    expect(items.count >= 56, "the full command list is there")
    for item in items {
        expect(item.keywords.contains("window") && item.keywords.contains("fenster"), "\(item.title) has window keywords")
        if case .symbol(let name) = item.icon { expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "symbol \(name) exists") }
    }
    // Tile Visible Windows: 2, 3 and 4 columns cover the screen edge to edge without gaps.
    for s in [a, b] {
        for n in 2...W.maxTiles {
            let c = W.columns(n, in: s)
            expect(c.count == n && c[0].minX == s.minX.rounded() && c[n - 1].maxX == s.maxX.rounded(), "\(n) columns span the screen")
            expect(zip(c, c.dropFirst()).allSatisfy { $0.maxX == $1.minX }, "\(n) columns share edges")
            expect(c.allSatisfy { $0.minY == s.minY && $0.height == s.height && abs($0.width - s.width / CGFloat(n)) <= 1 }, "\(n) equal full-height columns")
        }
        expect(W.columns(2, in: s) == [tile("Left Half", s), tile("Right Half", s)], "two columns are the halves")
        expect(W.columns(3, in: s) == ["First Third", "Center Third", "Last Third"].map { tile($0, s) }, "three columns are the thirds")
    }
    expect(W.keywords("Top Left Quarter") == ["window", "fenster", "oben", "links", "viertel"], "German keywords from the title")
    expect(W.keywords("Center", ["mitte"]) == ["window", "fenster", "mitte"], "keywords are not repeated")
}

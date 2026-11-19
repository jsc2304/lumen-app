import Foundation

// Checks for the shared parts: root preferences decoding and the ⌘↵ action.
func checkFoundation() {
    let decode = { (json: String) in try? JSONDecoder().decode(Root.Prefs.self, from: Data(json.utf8)) }
    expect(decode("{}")?.favorites == [], "root.json without keys still loads")
    expect(decode(#"{"favorites":["a"]}"#)?.favorites == ["a"] && decode(#"{"favorites":["a"]}"#)?.hotkeys.isEmpty == true,
           "root.json from before hotkeys existed keeps its favorites")

    let own = Action(title: "Open") {}
    let second = Action(title: "Show in Finder") {}
    let favorite = Action(title: "Add to Favorites", general: true) {}
    expect(Action.secondary(of: [own, second, favorite])?.title == "Show in Finder", "⌘↵ runs the item's own second action")
    expect(Action.secondary(of: [own, favorite]) == nil, "⌘↵ never toggles a favorite")
}

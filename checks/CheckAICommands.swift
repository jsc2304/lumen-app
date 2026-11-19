import Foundation

// Checks for AICommands.swift: storage shape, the visible list, form validation, copy titles, import and export.
// Only pure functions with explicit arguments: AICommands.custom and .hidden would read the real files.
func checkAICommands() {
    let decoder = JSONDecoder()
    func decode(_ json: String) -> [AICommand]? { try? decoder.decode([AICommand].self, from: Data(json.utf8)) }

    let old = decode(#"[{"title":"A","prompt":"p"}]"#)
    expect(old?.count == 1 && old?[0] == AICommand(id: old?[0].id, title: "A", symbol: "sparkles", prompt: "p", replaces: false),
           "a file without icon and replaces still loads")
    expect(decode(#"[{"title":"A"}]"#) == nil && decode(#"[{"prompt":"p"}]"#) == nil, "title and prompt are required")
    let tone = AICommand(title: "Tone", symbol: "text.bubble", prompt: "Soften {selection}", replaces: true)
    let exported = (try? AICommands.exportData([tone])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    expect(decode(exported) == [tone], "storage round trip")
    expect(exported == "[\n  {\n    \"icon\" : \"text.bubble\",\n    \"id\" : \"\(tone.id)\",\n    \"prompt\" : \"Soften {selection}\",\n    \"replaces\" : true,\n    \"title\" : \"Tone\"\n  }\n]",
           "export shape: id, title, prompt, icon, replaces")

    // Stable root ids: built-ins keep "ai.<title>", the user's own commands get "ai.custom.<uuid>" that never follows the title.
    expect(AICommands.builtIn.map(\.id) == AICommands.builtIn.map { "ai." + $0.title }, "built-ins keep the id they always had")
    expect(AICommands.builtIn.contains { $0.id == "ai.Fix Spelling and Grammar" }, "the starter command keeps its id")
    expect(tone.id.hasPrefix("ai.custom.") && UUID(uuidString: String(tone.id.dropFirst("ai.custom.".count))) != nil, "a new command gets ai.custom.<uuid>")
    expect(AICommand(title: "Tone", symbol: "star", prompt: "p", replaces: false).id != tone.id, "every new command gets its own id")
    let legacy = decode(#"[{"title":"A","prompt":"p"},{"title":"B","prompt":"q"},{"id":"ai.custom.fixed","title":"C","prompt":"r"}]"#)
    expect(legacy?.count == 3 && legacy?[0].id.hasPrefix("ai.custom.") == true && legacy?[0].id != legacy?[1].id && legacy?[2].id == "ai.custom.fixed",
           "entries without an id get one, a stored id is kept")
    let renamed = AICommands.command(from: ["Tone Softer", "p", "no", ""], id: tone.id)
    expect(renamed.id == tone.id && renamed.title == "Tone Softer" && AICommands.command(from: ["N", "p", "no", ""]).id != tone.id,
           "editing keeps the id, a new command gets another")
    let other = AICommand(title: "Other", symbol: "star", prompt: "x", replaces: false)
    let rootIDs = AIFeature.commands([tone, other]).map(\.id)
    expect(rootIDs.prefix(2) == [tone.id, other.id] && Set(rootIDs).count == rootIDs.count, "root ids are the command ids and do not collide")
    let chatNamed = AICommand(title: "chat", symbol: "star", prompt: "x", replaces: false)
    expect(Set(AIFeature.commands(AICommands.builtIn + [chatNamed]).map(\.id)).count == AICommands.builtIn.count + 1 + AIChat.commands().count,
           "a command titled like an AI Chat id does not collide with it")

    // The visible list: built-ins minus hidden ones, then custom; every title once.
    let names = AICommands.builtIn.map(\.title)
    expect(Set(names).count == names.count, "built-in titles are unique")
    expect(AICommands.combined(custom: [], hidden: []) == AICommands.builtIn, "no custom, nothing hidden: the built-ins")
    let mine = AICommand(title: "Mine", symbol: "star", prompt: "x", replaces: false)
    let shown = AICommands.combined(custom: [mine], hidden: ["Summarize", "Explain"])
    expect(shown.count == AICommands.builtIn.count - 2 + 1 && shown.last == mine && !shown.map(\.title).contains("Summarize"), "hidden built-ins vanish, custom ones follow")
    let clash = AICommand(title: "summarize", symbol: "star", prompt: "x", replaces: false)
    let dup = AICommands.combined(custom: [mine, mine, clash], hidden: [])
    expect(dup.filter { $0.title.lowercased() == "mine" }.count == 1 && !dup.contains(clash), "a repeated title (any case) shows once, built-in first")
    expect(AICommands.combined(custom: [clash], hidden: ["Summarize"]).contains(clash), "a hidden built-in frees its title")

    // Form validation: [title, prompt, paste, icon].
    let have = [mine]
    func problem(_ v: [String], editing: String? = nil) -> String? { AICommands.problem(v, custom: have, editing: editing) }
    expect(problem(["New", "Do it", "no", ""]) == nil, "valid")
    expect(problem(["  ", "Do it", "no", ""]) == "Enter a title.", "title required")
    expect(problem(["summarize", "Do it", "no", ""])?.contains("built-in") == true, "built-in titles are taken, in any case")
    expect(problem(["MINE", "Do it", "no", ""])?.contains("already have") == true, "custom titles are taken, in any case")
    expect(problem(["ai chat", "Do it", "no", ""])?.contains("AI Chat command") == true
           && problem(["Search AI Chats", "Do it", "no", ""])?.contains("AI Chat command") == true, "AI Chat command titles are taken, in any case")
    expect(problem(["Mine", "Do it", "no", ""], editing: "Mine") == nil, "an edited command keeps its title")
    expect(problem(["mine", "Do it", "no", ""], editing: "Mine") == nil, "and may change its case")
    expect(problem(["Summarize", "Do it", "no", ""], editing: "Mine") != nil, "but not take a built-in title")
    expect(problem(["New", " \n ", "no", ""]) == "Enter a prompt.", "prompt required")
    expect(problem(["New", "Do it", "maybe", ""]) == "Paste Result Over Selection must be yes or no.", "paste must be yes or no")
    expect(problem(["New", "Do it", "nein", "star"]) == nil && problem(["New", "Do it", "Ja", "  text.bubble "]) == nil, "ja, nein and a known symbol pass")
    expect(problem(["New", "Do it", "no", "stars"])?.contains("“stars” is not an SF Symbol") == true, "unknown icon names the icon")
    expect(AICommands.yesNo("Yes") == true && AICommands.yesNo(" JA ") == true && AICommands.yesNo("y") == true, "yes spellings")
    expect(AICommands.yesNo("no") == false && AICommands.yesNo("Nein") == false && AICommands.yesNo("") == false, "no spellings, empty means no")
    expect(AICommands.yesNo("1") == nil && AICommands.yesNo("yes please") == nil, "anything else is invalid")

    let made = AICommands.command(from: [" New ", "\nDo it\n", "ja", ""])
    expect(made == AICommand(id: made.id, title: "New", symbol: "sparkles", prompt: "Do it", replaces: true), "form values become a command, empty icon is the default")
    expect(AICommands.command(from: ["N", "p", "no", " star "]).symbol == "star", "icon is trimmed")

    expect(AICommands.copyTitle(of: "Mine", custom: have) == "Mine Copy", "copy title")
    expect(AICommands.copyTitle(of: "Mine", custom: have + [AICommand(title: "mine copy", symbol: "star", prompt: "x", replaces: false)]) == "Mine Copy 2", "copy title skips a taken one")
    expect(AICommands.copyTitle(of: "Translate to German", custom: []) == "Translate to German Copy", "a built-in can be duplicated")

    // Import: Raycast's export shape, ours, junk.
    let raycast = #"[{"title":"Tone","prompt":"Soften it","icon":"stars","creativity":"medium","model":"some-model","id":"x"},"#
        + #"{"title":"Summarize","prompt":"clash with a built-in"},{"title":"Mine","prompt":"clash with existing"},"#
        + #"{"title":"  ","prompt":"no title"},{"title":"No prompt"},{"name":"Named","prompt":"uses name","icon":"star"},"#
        + #"{"title":"Tone","prompt":"same title twice"},{"title":"Ours","prompt":"p","icon":"text.bubble","replaces":true,"id":"ai.chat"},"#
        + #"{"title":"Search AI Chats","prompt":"clash with an AI Chat command"}]"#
    let r = AICommands.imported(Data(raycast.utf8), existing: have)
    expect(r?.new.map(\.title) == ["Tone", "Named", "Ours"] && r?.skipped == 6, "import adds new titles, skips clashes and incomplete ones")
    expect(r?.new[0] == AICommand(id: r?.new[0].id, title: "Tone", symbol: "sparkles", prompt: "Soften it", replaces: false), "a Raycast icon becomes the default, replaces defaults to no")
    expect(r?.new[1].symbol == "star" && r?.new[2] == AICommand(id: r?.new[2].id, title: "Ours", symbol: "text.bubble", prompt: "p", replaces: true),
           "known icons and replaces survive")
    expect(r?.new.allSatisfy { $0.id.hasPrefix("ai.custom.") } == true && Set(r?.new.map(\.id) ?? []).count == 3, "imported commands get ids of their own, a file's id is ignored")
    expect(AICommands.imported(Data("[]".utf8), existing: have)?.new.isEmpty == true, "an empty list imports nothing")
    expect(AICommands.imported(Data(#"{"title":"A","prompt":"p"}"#.utf8), existing: have) == nil && AICommands.imported(Data("nope".utf8), existing: have) == nil,
           "anything but a list is refused")
    let again = (try? AICommands.exportData(r?.new ?? [])).flatMap { AICommands.imported($0, existing: []) }
    func fields(_ list: [AICommand]?) -> [[String]]? { list?.map { [$0.title, $0.symbol, $0.prompt, "\($0.replaces)"] } }
    expect(fields(again?.new) == fields(r?.new) && again?.skipped == 0, "our export imports back unchanged")
}

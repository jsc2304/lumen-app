import Foundation

/// Wires feature files into the root search. A new feature adds its commands (and, if it has them,
/// query items, fallbacks or upcoming items) here; everything else lives in its own file.
enum Features {
    static func commands() -> [Item] {
        Schedule.shared.commands() + Mite.commands() + GitHub.commands() + Clipboard.shared.commands() + Snippets.shared.commands() + Quicklinks.commands()
            + Emoji.commands() + Calculator.commands() + Navigation.commands() + System.commands()
            + WindowCommands.items() + AIFeature.commands() + AICommands.commands() + Notes.commands() + Scripts.commands()
            + Lookup.commands() + Files.commands() + Focus.commands() + AppTools.commands() + System.lumenCommands()
    }

    /// Items computed from the query itself, shown above the ranked results (calculator, quicklinks, URLs).
    static func queryItems(_ q: String) -> [Item] {
        Calculator.items(q) + Quicklinks.queryItems(q) + (Lookup.defineWord(in: q).flatMap(Lookup.defineItem).map { [$0] } ?? [])
    }

    /// Offered at the end of every non-empty search.
    static func fallbacks(_ q: String) -> [Item] {
        [AIFeature.askItem(q)] + Quicklinks.fallbacks(q)
    }

    /// Shown at the top of the empty root search (the next meeting, …).
    static func upcoming() -> [Item] {
        Schedule.shared.upcoming()
    }

    /// Root entries suggested before Lumen has learned anything.
    static let starters = ["cal.schedule", "cmd.clipboard", "ai.Fix Spelling and Grammar"]
}

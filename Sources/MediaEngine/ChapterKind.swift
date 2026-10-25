import Foundation

extension Chapter {
    /// What a chapter is for, guessed from its title. Chapters have no type in the container, so this is a
    /// conservative reading of the titles that release groups and discs use ("OP", "Opening 2", "Ending", "Recap",
    /// "Next episode preview", ...); anything else is `.content`. Apps can offer "Skip Opening" for `.opening` and so on.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// The opening theme sequence of an episode.
        case opening
        /// The ending theme sequence of an episode.
        case ending
        /// A series or title introduction.
        case intro
        /// A summary of what happened before.
        case recap
        /// A preview of the next episode or a trailer.
        case preview
        /// Closing credits or a staff roll.
        case credits
        /// Everything else: the story itself.
        case content
    }

    /// The kind of this chapter, read from its title (see ``Kind``).
    public var kind: Kind { Kind.classify(title) }

    /// Whether an app would offer to skip this chapter (everything except `.content`).
    public var isSkippable: Bool { kind != .content }
}

extension Chapter.Kind {
    /// Whole-title patterns only, so "Opening Scene" or "Ending Explained" in a film stay content.
    private static let patterns: [(Chapter.Kind, String)] = [
        (.opening, #"^(nc)?(op|opening)(\s*(#|no\.?)?\s*\d+)?(\s+(theme|song|credits|sequence|animation|movie))?(\s*\(.*\))?$"#),
        (.opening, #"^(オープニング|オープニングテーマ|опенинг|заставка)(\s*\d+)?$"#),
        (.ending, #"^(nc)?(ed|ending)(\s*(#|no\.?)?\s*\d+)?(\s+(theme|song|credits|sequence|animation|movie))?(\s*\(.*\))?$"#),
        (.ending, #"^(エンディング|エンディングテーマ|эндинг|финальные титры)(\s*\d+)?$"#),
        (.credits, #"^((end|closing|staff|final)\s+)?(credits|roll)$"#),
        (.credits, #"^(スタッフロール|титры)$"#),
        (.intro, #"^(intro|introduction|title sequence|main title|cold open)$"#),
        (.recap, #"^(recap|previously(\s+on)?(\s+.*)?|story so far|あらすじ|前回のあらすじ|ранее)$"#),
        (.preview, #"^(preview|next(\s+episode)?(\s+preview)?|trailer|予告|次回予告|превью|в следующей серии)$"#),
    ]

    static func classify(_ title: String?) -> Chapter.Kind {
        guard let title else { return .content }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .content }
        for (kind, pattern) in patterns where normalized.range(of: pattern, options: .regularExpression) != nil {
            return kind
        }
        return .content
    }
}

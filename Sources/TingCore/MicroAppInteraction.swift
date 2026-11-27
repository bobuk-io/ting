import BobukCore
import Foundation

/// A rendered request for user input. No answers are persisted by the runner.
public enum MicroAppInteraction: Equatable, Sendable {
    public struct Choice: Equatable, Sendable, Identifiable {
        /// Position in the original list; duplicate labels and values remain separate choices.
        public var id: Int
        public var title: String
        public var subtitle: String?
        public var value: String

        public init(id: Int, title: String, subtitle: String? = nil, value: String) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.value = value
        }
    }

    case preview(text: String, style: MicroApp.OutputStyle)
    /// `details`: the selected option's value is shown beside the list.
    case choose(prompt: String, choices: [Choice], details: Bool = false)
    case ask(prompt: String, defaultValue: String, placeholder: String, multiline: Bool, required: Bool)

    public var prompt: String {
        switch self {
        case .preview: "Preview"
        case .choose(let prompt, _, _), .ask(let prompt, _, _, _, _): prompt
        }
    }

    public struct InvalidInput: Error, Equatable, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// One nonempty line per choice, or a JSON array of strings / title-subtitle-value objects.
    /// JSON-looking input is validated, never silently displayed as broken JSON lines.
    public static func choices(from input: String) throws -> [Choice] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let choices: [Choice]
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            let json: Any
            do { json = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) }
            catch { throw InvalidInput("choose: invalid JSON list") }
            guard let items = json as? [Any] else { throw InvalidInput("choose: expected a JSON array") }
            choices = try items.enumerated().map { index, item in
                if let text = item as? String {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw InvalidInput("choose: a title must not be empty")
                    }
                    return Choice(id: index, title: text, value: text)
                }
                guard let object = item as? [String: Any], let title = object["title"] as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let value = object["value"] as? String,
                      object["subtitle"] == nil || object["subtitle"] is String else {
                    throw InvalidInput("choose: each item needs string title and value, and an optional string subtitle")
                }
                return Choice(id: index, title: title, subtitle: object["subtitle"] as? String, value: value)
            }
        } else {
            choices = input.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .enumerated().map { Choice(id: $0.offset, title: $0.element, value: $0.element) }
        }
        guard !choices.isEmpty else { throw InvalidInput("No options") }
        return choices
    }

    /// Front ends cannot return an arbitrary answer to a choose request.
    public func validate(_ answer: String) throws -> String {
        switch self {
        case .preview: return ""
        case .choose(_, let choices, _):
            guard choices.contains(where: { $0.value == answer }) else { throw InvalidInput("Choose an available option") }
        case .ask(_, _, _, _, let required):
            if required && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw InvalidInput("Enter text to continue")
            }
        }
        return answer
    }

    /// Filters `choices` by `query`, ranking title matches above subtitle-only matches.
    ///
    /// Order: non-typo title match, non-typo subtitle match, typo title match, typo subtitle match;
    /// within each group: better `FuzzyMatchKind`, higher alignment score, then original order.
    /// When nothing matches, a 3-letter query is tried again with one typo (`FuzzyQuery.hasFallback`).
    /// A query without letters or digits keeps every choice in order.
    public static func filterChoices(_ choices: [Choice], matching query: String) -> [Choice] {
        let prepared = FuzzyQuery(query)
        guard !prepared.isEmpty else { return choices }
        func collect(fallback: Bool) -> [(offset: Int, choice: Choice, rank: Int, match: FuzzyMatch)] {
            choices.enumerated().compactMap { offset, choice in
                let title = prepared.match(choice.title, fallback: fallback)
                let subtitle = choice.subtitle.flatMap { prepared.match($0, fallback: fallback) }
                let picked: (rank: Int, match: FuzzyMatch)?
                switch (title, subtitle) {
                case (let t?, _) where t.kind != .typo:
                    picked = (0, t)
                case (_, let s?) where s.kind != .typo:
                    picked = (1, s)
                case (let t?, _):
                    picked = (2, t)
                case (nil, let s?):
                    picked = (3, s)
                case (nil, nil):
                    picked = nil
                }
                guard let picked else { return nil }
                return (offset, choice, picked.rank, picked.match)
            }
        }
        var found = collect(fallback: false)
        if found.isEmpty, prepared.hasFallback {
            found = collect(fallback: true)
        }
        return found
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.match.kind != rhs.match.kind { return lhs.match.kind < rhs.match.kind }
                if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
                return lhs.offset < rhs.offset
            }
            .map(\.choice)
    }
}

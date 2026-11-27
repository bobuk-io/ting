import BobukCore
import Foundation

/// The remembered values: by micro-app id, the parameter values of the last started run, as plain text.
/// Stored as `micro-values.json`, apart from the micro-apps folder and the config file.
/// JSON: {"version": 1, "values": {"dns-lookup": {"domain": "example.com", "record": "MX"}}}.
public struct MicroAppRememberedValues: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int = MicroAppRememberedValues.currentVersion
    /// Micro-app id → parameter name → value.
    public var values: [String: [String: String]] = [:]

    public init(values: [String: [String: String]] = [:]) {
        self.values = values
    }

    /// The remembered values of `app`; none when the app has `remember: false`.
    public func values(for app: MicroApp) -> [String: String] {
        app.remember ? values[app.id] ?? [:] : [:]
    }

    /// Keeps `shown` as the values of `app`: only its declared parameters, so the values of removed
    /// parameters are dropped. A micro-app with `remember: false` or without parameters keeps nothing.
    public mutating func remember(_ shown: [String: String], for app: MicroApp) {
        guard app.remember, !app.params.isEmpty else {
            values[app.id] = nil
            return
        }
        var kept: [String: String] = [:]
        for param in app.params {
            if let value = shown[param.name] { kept[param.name] = value }
        }
        values[app.id] = kept
    }

    private enum CodingKeys: String, CodingKey { case version, values }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        values = try container.decodeIfPresent([String: [String: String]].self, forKey: .values) ?? [:]
    }

    /// Sorted, pretty-printed JSON ending with "\n".
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        data.append(contentsOf: Array("\n".utf8))
        return data
    }

    /// The stored values. Anything that is not a readable file of this format gives no values: every
    /// form then starts from the defaults.
    public static func decode(_ data: Data) -> MicroAppRememberedValues {
        guard let decoded = try? JSONDecoder().decode(MicroAppRememberedValues.self, from: data),
              decoded.version <= currentVersion else { return MicroAppRememberedValues() }
        return decoded
    }
}

/// The parameter panel of one start: one field per parameter, in file order, with its start value.
public struct MicroAppForm: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var param: MicroApp.Param
        /// The shown value: the text of a text field, the marked option of a choice field.
        public var value: String
        /// The start value came from the remembered values.
        public var isRemembered: Bool

        public init(param: MicroApp.Param, value: String, isRemembered: Bool) {
            self.param = param
            self.value = value
            self.isRemembered = isRemembered
        }

        public var isOptional: Bool { !param.required }
        public var choices: [String]? {
            if case .choice(let options) = param.kind { return options }
            return nil
        }
    }

    public var fields: [Field]
    /// The optional fields are visible.
    public var optionalOpen: Bool

    public init(fields: [Field], optionalOpen: Bool) {
        self.fields = fields
        self.optionalOpen = optionalOpen
    }

    /// The start value of one parameter:
    /// - a remembered value, when it is still valid (a choice value must still be one of the choices);
    /// - else the default of an optional parameter;
    /// - else the first option of a required choice;
    /// - else the empty text.
    public static func startValue(of param: MicroApp.Param, remembered: String?) -> (value: String, isRemembered: Bool) {
        let choices: [String]? = if case .choice(let options) = param.kind { options } else { nil }
        if let remembered, choices.map({ $0.contains(remembered) }) ?? true {
            return (remembered, true)
        }
        if let defaultValue = param.defaultValue, choices.map({ $0.contains(defaultValue) }) ?? true {
            return (defaultValue, false)
        }
        return (choices?.first ?? "", false)
    }

    /// The form at the start of `app`. Values of parameters that are no longer declared are ignored;
    /// `remember: false` always gives the clean form. The optional part starts open when every
    /// parameter is optional, or when a remembered optional value differs from its default.
    public static func start(_ app: MicroApp, remembered: MicroAppRememberedValues) -> MicroAppForm {
        let memory = remembered.values(for: app)
        let fields = app.params.map { param in
            let start = startValue(of: param, remembered: memory[param.name])
            return Field(param: param, value: start.value, isRemembered: start.isRemembered)
        }
        let allOptional = !fields.isEmpty && fields.allSatisfy(\.isOptional)
        let changedOptional = fields.contains { $0.isOptional && $0.isRemembered && $0.value != $0.param.defaultValue }
        return MicroAppForm(fields: fields, optionalOpen: allOptional || changedOptional)
    }

    /// A micro-app with no parameters has no parameter panel.
    public var isEmpty: Bool { fields.isEmpty }

    /// One choice parameter and nothing else: the panel is an open list, and Enter chooses and runs.
    public var isSingleChoiceList: Bool {
        fields.count == 1 && fields[0].choices != nil
    }

    /// The optional part can be opened and closed (⌘O and the icon): there are optional fields and at
    /// least one required field. With only optional fields they are always visible.
    public var hasOptionalToggle: Bool {
        fields.contains(where: \.isOptional) && fields.contains(where: { !$0.isOptional })
    }

    /// The indexes of the visible fields, in file order: required ones always, optional ones when open.
    public var visibleIndexes: [Int] {
        fields.indices.filter { !fields[$0].isOptional || optionalOpen || !hasOptionalToggle }
    }

    /// The visible field after (or before, with `by: -1`) `index`, wrapping around: what Tab moves to.
    public func nextVisible(after index: Int, by step: Int = 1) -> Int? {
        let visible = visibleIndexes
        guard !visible.isEmpty else { return nil }
        guard let position = visible.firstIndex(of: index) else { return visible.first }
        let count = visible.count
        return visible[((position + step) % count + count) % count]
    }

    /// The first required text field with empty text: Enter does not run, and this field gets the focus
    /// and the mark. Text of only spaces counts as empty.
    public var firstMissingRequired: Int? {
        fields.indices.first { index in
            let field = fields[index]
            return field.param.required && field.choices == nil
                && field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Why Enter cannot run yet.
    public enum Block: Equatable, Sendable {
        /// A required text field is empty.
        case emptyRequired
        /// The letters typed in a choice field match no option, so no option is shown as the value.
        case noOption
    }

    /// The first field, in file order, that stops Enter: an empty required text, or a choice field
    /// whose typed letters (`queries`, by field index) match no option. That field gets the focus and
    /// the mark; `nil` means Enter runs with `values`.
    public func firstBlocked(queries: [Int: String] = [:]) -> (index: Int, block: Block)? {
        for index in fields.indices {
            if index == firstMissingRequired { return (index, .emptyRequired) }
            if let choices = fields[index].choices, let query = queries[index],
               MicroAppChoiceFilter.options(choices, matching: query).isEmpty {
                return (index, .noOption)
            }
        }
        return nil
    }

    /// The shown values by parameter name: what the command gets as `TING_` variables and what is
    /// remembered. A hidden optional field gives its shown value too (its default unless changed);
    /// an optional text made empty gives the empty text.
    public var values: [String: String] {
        Dictionary(fields.map { ($0.param.name, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Letters typed in a choice field filter its options.
public enum MicroAppChoiceFilter {
    /// The options that `query` matches fuzzily (`FuzzyMatcher`: case, diacritics, scattered
    /// letters, typos in longer queries, the wrong keyboard layout). Better matches come first:
    /// exact, prefix, word start, initials, substring, scattered, typo; file order within equals.
    /// A query without letters or digits gives every option.
    public static func options(_ choices: [String], matching query: String) -> [String] {
        FuzzyMatcher.filter(choices, matching: query) { [$0] }
    }

    /// The marked option after the filter changed: the marked one while it still matches, else the
    /// first match; `nil` when nothing matches (the value then stays as it was).
    public static func mark(_ current: String, in filtered: [String]) -> String? {
        filtered.contains(current) ? current : filtered.first
    }

    /// The option `step` places from `current` in `filtered`, stopping at the ends.
    public static func move(_ current: String, by step: Int, in filtered: [String]) -> String? {
        guard !filtered.isEmpty else { return nil }
        guard let position = filtered.firstIndex(of: current) else { return filtered.first }
        return filtered[min(max(position + step, 0), filtered.count - 1)]
    }
}

/// The height rules of the parameter panel: the form scrolls inside the flow panel's cap.
public enum MicroAppFormLayout {
    /// The flow panel is never taller than this.
    public static let panelCap: Double = 680
    /// The card's title, footer, paddings and shadow around the form.
    public static let chrome: Double = 150
    /// The smallest form height, so a low screen still shows a field.
    public static let minimumFormHeight: Double = 80

    /// The highest form height inside a flow panel of `panelHeight` points.
    public static func maxFormHeight(panelHeight: Double) -> Double {
        max(minimumFormHeight, min(panelHeight, panelCap) - chrome)
    }

    /// The shown form height: the content height, but never more than the max; beyond it the form scrolls.
    public static func formHeight(content: Double, panelHeight: Double) -> Double {
        min(content, maxFormHeight(panelHeight: panelHeight))
    }

    /// `true` when the content is taller than the space and the form must scroll.
    public static func scrolls(content: Double, panelHeight: Double) -> Bool {
        content > maxFormHeight(panelHeight: panelHeight)
    }
}

/// Width and typography rules of the micro-app flow panel.
public enum MicroAppPanelLayout {
    /// Default card width for dialogs (approval, forms, non-preview prompts) and default result panels.
    public static let defaultCardWidth: Double = Double(MicroAppsSettings.defaultResultWidth)
    /// Minimum card width of a `choose` with `details`: the list plus the value beside it.
    public static let choiceDetailsCardWidth: Double = 820
    /// Width of the option list when details are shown beside it.
    public static let choiceDetailsListWidth: Double = 300
    /// Horizontal space around the card inside the window, for its shadow.
    public static let panelHorizontalMargin: Double = 60
    /// Horizontal screen margin kept outside the panel.
    public static let screenHorizontalMargin: Double = 40
    /// Horizontal padding inside the card around `SelectableText` (card padding + text inset + line padding).
    public static let textHorizontalInset: Double = 40 + 12 + 10

    /// Window width for a card of `cardWidth` points, clamped to `visibleWidth` when a screen width is given.
    public static func panelWidth(cardWidth: Double, visibleWidth: Double? = nil) -> Double {
        let desired = cardWidth + panelHorizontalMargin
        guard let visibleWidth else { return desired }
        let cap = max(320, visibleWidth - screenHorizontalMargin)
        return min(desired, cap)
    }

    /// Card width that fits inside `panelWidth(cardWidth:visibleWidth:)`.
    public static func effectiveCardWidth(cardWidth: Double, visibleWidth: Double? = nil) -> Double {
        max(260, panelWidth(cardWidth: cardWidth, visibleWidth: visibleWidth) - panelHorizontalMargin)
    }

    /// Text container width inside a card of `cardWidth` points.
    public static func textWidth(cardWidth: Double) -> Double {
        max(120, cardWidth - textHorizontalInset)
    }

    /// Monospaced font size paired with `bodySize`.
    public static func monoSize(forBodySize bodySize: Double) -> Double {
        max(10, bodySize - 1)
    }

    /// Heading font sizes (H1…H6) scaled from `bodySize`. At the 13pt default: 20, 17, 15, 14, 13, 13.
    public static func headingSize(level: Int, bodySize: Double) -> Double {
        let offsets: [Double] = [7, 4, 2, 1, 0, 0]
        let clamped = min(max(level, 1), 6) - 1
        return bodySize + offsets[clamped]
    }
}

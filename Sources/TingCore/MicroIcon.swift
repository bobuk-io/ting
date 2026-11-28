import Foundation

/// The icon of a micro-app in the leader menu, launcha and Settings.
/// From the `icon` key of the file, or from `microIcons` of the config, which wins.
public enum MicroIcon: Equatable, Sendable {
    /// One visible character: an emoji or any glyph of the system font.
    case glyph(String)
    /// An SF Symbol name, such as `globe`. A name macOS does not have shows the default icon.
    case symbol(String)

    /// The SF Symbol of a micro-app without an icon.
    public static let defaultSymbol = "terminal"
    public static let rule = "one character (an emoji or a letter) or an SF Symbol name such as `globe`"

    /// `nil` when `text` is neither one character nor shaped like an SF Symbol name.
    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count == 1 {
            // One character can be any number of combining marks, or only an invisible one.
            let scalars = text.unicodeScalars
            let invisible: Set<Unicode.GeneralCategory> = [.format, .control, .nonspacingMark, .enclosingMark]
            guard scalars.count <= 16, scalars.contains(where: { !invisible.contains($0.properties.generalCategory) }) else { return nil }
            self = .glyph(text)
        } else if (2...64).contains(text.count), text.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == ".") }) {
            self = .symbol(text)
        } else {
            return nil
        }
    }
}

extension MicroAppCatalog {
    /// The icon of the micro-app `id`: the `microIcons` entry of the config when it is valid,
    /// else the `icon` key of a working file, else `nil` (the default icon).
    public func icon(_ id: String) -> MicroIcon? {
        if let override = iconOverrides[id].flatMap(MicroIcon.init) { return override }
        if case .working(let app, _) = resolve(id) { return app.icon }
        return nil
    }
}

import Foundation

/// The versioned index of the official gallery. A listing maps to `<id>.yaml` in the same
/// directory; the index cannot point Ting at another host or choose a destination path.
public struct MicroAppGallery: Decodable, Sendable {
    public struct Listing: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let description: String
        public let dataAccess: String
        public let requirements: String
        public let minimumTingVersion: String
        public let sha256: String

        public var fileName: String { "\(id).\(MicroAppChecker.fileExtension)" }

        public func supports(tingVersion: String) -> Bool {
            guard let current = MicroAppGallery.version(tingVersion),
                  let minimum = MicroAppGallery.version(minimumTingVersion) else { return false }
            return !current.lexicographicallyPrecedes(minimum)
        }

        /// Validate exact bytes before installing. No local libraries are supplied: gallery apps
        /// must work as standalone files. Validation parses the file but never runs it.
        public func validate(_ data: Data, maxTimeLimit: Int = MicroAppChecker.maxTimeLimit) throws {
            guard data.count <= MicroAppChecker.maxFileSize else { throw Problem.tooLarge }
            guard MicroAppApprovals.hash(data) == sha256 else { throw Problem.hashMismatch }
            guard let text = String(data: data, encoding: .utf8) else {
                throw Problem.invalidApp(MicroAppChecker.notUTF8Message)
            }
            switch MicroAppChecker.check(text, fileName: fileName, maxTimeLimit: maxTimeLimit) {
            case .failure(let failure): throw Problem.invalidApp(failure.description)
            case .success(let app):
                guard app.id == id else { throw Problem.wrongID }
                guard !app.hidden else { throw Problem.invalidApp("Gallery micro-apps must be visible.") }
            }
        }
    }

    public enum Problem: LocalizedError, Equatable {
        case invalidCatalog, tooLarge, hashMismatch, invalidApp(String), wrongID, alreadyExists

        public var errorDescription: String? {
            switch self {
            case .invalidCatalog: "Ting could not read this gallery catalog."
            case .tooLarge: "The gallery download exceeds Ting’s size limit."
            case .hashMismatch: "The download does not match the listing. Refresh the gallery and try again."
            case .invalidApp(let details): "The gallery micro-app is invalid: \(details)"
            case .wrongID: "The micro-app ID does not match the gallery listing."
            case .alreadyExists: "A local micro-app already uses this ID or file name. Ting did not replace it."
            }
        }
    }

    public static let maxIndexSize = 256 * 1024
    public let listings: [Listing]

    public init(from decoder: Decoder) throws {
        let index = try decoder.container(keyedBy: CodingKeys.self)
        guard try index.decode(Int.self, forKey: .version) == 1 else { throw Problem.invalidCatalog }
        listings = try index.decode([Listing].self, forKey: .listings)
        var ids = Set<String>()
        for listing in listings {
            guard listing.id.utf8.count <= 80, MicroAppChecker.isKebabCase(listing.id),
                  ids.insert(listing.id).inserted, Self.version(listing.minimumTingVersion) != nil,
                  listing.sha256.utf8.count == 64, listing.sha256.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0)
                  }), [listing.title, listing.description, listing.dataAccess, listing.requirements]
                    .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw Problem.invalidCatalog
            }
        }
    }

    /// Search listing metadata locally. Every word must match somewhere in the listing.
    public func matching(_ query: String) -> [Listing] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return listings }
        return listings.filter { listing in
            let fields = [listing.id, listing.title, listing.description, listing.dataAccess, listing.requirements]
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxIndexSize else { throw Problem.tooLarge }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw Problem.invalidCatalog }
    }

    private enum CodingKeys: String, CodingKey { case version, listings }

    private static func version(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        return parts.count == 3 && numbers.count == 3 ? numbers : nil
    }
}

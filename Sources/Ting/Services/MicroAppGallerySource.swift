import Foundation
import TingCore

/// Only the official GitHub gallery is fetched; browsing does not download any micro-app files.
enum MicroAppGallerySource {
    static let webURL = URL(string: "https://github.com/bobuk-io/ting/tree/main/docs/micro-apps/gallery")!
    private static let rawURL = URL(string: "https://raw.githubusercontent.com/bobuk-io/ting/main/docs/micro-apps/gallery/")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static var isPreview: Bool { previewFolder != nil }

    private static let previewFolder: URL? = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["TING_GALLERY_PREVIEW"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return nil
    }()

    static func index() async throws -> MicroAppGallery {
        let data = try await fetch("catalog.json", limit: MicroAppGallery.maxIndexSize)
        return try MicroAppGallery.decode(data)
    }

    static func download(_ listing: MicroAppGallery.Listing) async throws -> Data {
        try await fetch(listing.fileName, limit: MicroAppChecker.maxFileSize)
    }

    private static func fetch(_ fileName: String, limit: Int) async throws -> Data {
        if let previewFolder {
            let file = try FileHandle(forReadingFrom: previewFolder.appendingPathComponent(fileName))
            defer { try? file.close() }
            let data = try file.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw MicroAppGallery.Problem.tooLarge }
            return data
        }
        let (bytes, response) = try await session.bytes(from: rawURL.appendingPathComponent(fileName))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard response.expectedContentLength <= Int64(limit) else { throw MicroAppGallery.Problem.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw MicroAppGallery.Problem.tooLarge }
            data.append(byte)
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

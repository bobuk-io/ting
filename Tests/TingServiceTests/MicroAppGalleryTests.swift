import AppKit
import SwiftUI
import XCTest
import TingCore
@testable import Ting

@MainActor
final class MicroAppGalleryTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/micro-apps/gallery", isDirectory: true)

    private func index() throws -> MicroAppGallery {
        try MicroAppGallery.decode(Data(contentsOf: Self.folder.appendingPathComponent("catalog.json")))
    }

    private func fixture(_ id: String = "count-text") throws -> (MicroAppGallery.Listing, Data) {
        let listing = try XCTUnwrap(index().listings.first { $0.id == id })
        return (listing, try Data(contentsOf: Self.folder.appendingPathComponent(listing.fileName)))
    }

    private func store() throws -> (MicroAppStore, [String: String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ting-gallery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("config.json")
        let environment = ["TING_CONFIG": config.path]
        return (MicroAppStore(configURL: config, environment: environment), environment)
    }

    func testRenderGalleryPreviewOffscreen() async throws {
        guard let output = ProcessInfo.processInfo.environment["TING_GALLERY_IMAGE"] else { return }
        XCTAssertTrue(MicroAppGallerySource.isPreview, "Set TING_GALLERY_PREVIEW to the local catalog folder")
        guard MicroAppGallerySource.isPreview else { return }
        _ = NSApplication.shared
        let (_, environment) = try store()
        let config = URL(fileURLWithPath: try XCTUnwrap(environment["TING_CONFIG"]))
        let model = AppModel(presentsWindows: false, store: ConfigStore(url: config))
        let hosting = NSHostingView(rootView: MicroAppGalleryView(tingVersion: TingVersion.marketing)
            .environment(model).environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let size = hosting.fittingSize
        XCTAssertGreaterThan(size.height, 350, "The loaded scroll view should be visible")
        XCTAssertFalse(window.isVisible)
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }

    func testPublishedCatalogMatchesEveryStandaloneYAML() throws {
        let listings = try index().listings
        let yaml = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path)
            .filter { $0.hasSuffix(".yaml") }
        XCTAssertFalse(listings.isEmpty)
        XCTAssertEqual(Set(yaml), Set(listings.map(\.fileName)))
        for listing in listings {
            let data = try Data(contentsOf: Self.folder.appendingPathComponent(listing.fileName))
            XCTAssertNoThrow(try listing.validate(data), listing.fileName)
        }
    }

    func testSearchMatchesWordsAcrossListingFields() throws {
        let gallery = try index()
        XCTAssertEqual(gallery.matching(" \n ").map(\.id), gallery.listings.map(\.id))
        XCTAssertEqual(gallery.matching("  jSOn ").map(\.id), ["format-json"])
        XCTAssertEqual(gallery.matching("markdown Automation").map(\.id), ["copy-page-link"])
        XCTAssertEqual(gallery.matching("bundle Accessibility").map(\.id), ["app-info"])
        XCTAssertEqual(gallery.matching("change-case").map(\.id), ["change-case"])
        XCTAssertTrue(gallery.matching("json zzz-not-a-listing").isEmpty)
    }

    func testRefusesInvalidIndexAndComparesVersionsNumerically() throws {
        let listing = try fixture().0
        XCTAssertTrue(listing.supports(tingVersion: listing.minimumTingVersion))
        XCTAssertTrue(listing.supports(tingVersion: "0.10.0"))
        XCTAssertFalse(listing.supports(tingVersion: "0.7.9"))
        XCTAssertFalse(listing.supports(tingVersion: "dev"))

        let row: [String: String] = [
            "id": "safe-id", "title": "Tool", "description": "Example", "dataAccess": "None",
            "requirements": "None", "minimumTingVersion": "0.10.0", "sha256": String(repeating: "a", count: 64),
        ]
        let traversal = row.merging(["id": "../package"]) { _, value in value }
        let badHash = row.merging(["sha256": "not-a-hash"]) { _, value in value }
        for invalid in [[traversal], [row, row], [badHash]] {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "listings": invalid])
            XCTAssertThrowsError(try MicroAppGallery.decode(data)) {
                XCTAssertEqual($0 as? MicroAppGallery.Problem, .invalidCatalog)
            }
        }
    }

    func testInstallKeepsExactBytesAndDoesNotGrantApproval() throws {
        let (listing, data) = try fixture()
        let (store, environment) = try store()
        try store.installFromGallery(data, listing: listing)
        let destination = store.folderURL.appendingPathComponent(listing.fileName)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        let catalog = store.load()
        XCTAssertEqual(catalog.apps.map(\.id), [listing.id])
        XCTAssertEqual(catalog.entries.first?.contentHash, listing.sha256)
        let approvals = MicroAppApprovalStore(url: MicroAppApprovalStore.defaultURL(environment: environment))
        approvals.load()
        guard case .approve = MicroAppStartStep.first(id: listing.id, catalog: catalog,
                                                     approvals: approvals.approvals, folder: store.displayPath) else {
            return XCTFail("A new gallery app must require approval on first run")
        }
    }

    func testInstallRejectsModifiedDownloadAndLocalIDCollision() throws {
        let (listing, data) = try fixture()
        let (store, _) = try store()
        var extra = data
        extra.append(0x0A)
        XCTAssertThrowsError(try store.installFromGallery(extra, listing: listing)) {
            XCTAssertEqual($0 as? MicroAppGallery.Problem, .hashMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folderURL.path))
        try FileManager.default.createDirectory(at: store.folderURL, withIntermediateDirectories: true)
        let existing = store.folderURL.appendingPathComponent("custom.yaml")
        let custom = Data("id: \(listing.id)\n".utf8) + data
        try custom.write(to: existing)
        XCTAssertThrowsError(try store.installFromGallery(data, listing: listing)) {
            XCTAssertEqual($0 as? MicroAppGallery.Problem, .alreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: existing), custom)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folderURL.path), ["custom.yaml"])
    }

    func testInstallNeverReplacesDanglingSymlink() throws {
        let (listing, data) = try fixture()
        let (store, _) = try store()
        try FileManager.default.createDirectory(at: store.folderURL, withIntermediateDirectories: true)
        let destination = store.folderURL.appendingPathComponent(listing.fileName)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "missing.yaml")
        XCTAssertThrowsError(try store.installFromGallery(data, listing: listing)) {
            XCTAssertEqual($0 as? MicroAppGallery.Problem, .alreadyExists)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "missing.yaml")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.folderURL.path), [listing.fileName])
    }
}

import BobukUI
import SwiftUI
import TingCore

struct MicroAppGalleryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var gallery: MicroAppGallery?
    @State private var query = ""
    @State private var catalogError: String?
    @State private var refresh = 0
    @State private var installing: MicroAppGallery.Listing?
    @State private var installed: MicroAppGallery.Listing?
    @State private var installError: String?

    private let tingVersion: String

    init(tingVersion: String = AgentPromptSource.version(bundle: .main)) {
        self.tingVersion = tingVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Micro-app Gallery").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(MicroAppGallerySource.isPreview ? "Local gallery preview — not from GitHub." : "Curated by Ting.")
                .foregroundStyle(.secondary)
            Text("Installing adds a file; it does not run it or grant approval.")
                .foregroundStyle(.secondary)
            if let installed {
                Text("Installed \(installed.title)").font(.headline)
                Text("Record a shortcut, or skip to set it later in Micro-apps. Ting asks you to review new code on first run.")
                    .fixedSize(horizontal: false, vertical: true)
                MicroHotkeyCell(micro: installed.id)
                    .id(installed.id)
            } else {
                catalogContent
            }
            HStack {
                Link("View on GitHub", destination: MicroAppGallerySource.webURL)
                if installed == nil, gallery != nil || catalogError != nil {
                    Button("Refresh") { refresh += 1 }.disabled(installing != nil)
                }
                Spacer()
                if installed != nil {
                    Button("Back to Gallery") { installed = nil }
                }
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 560)
        .task(id: refresh) { await load() }
        .task(id: installing?.id) {
            if let listing = installing { await install(listing) }
        }
    }

    @ViewBuilder private var catalogContent: some View {
        if let gallery {
            if gallery.listings.isEmpty {
                Text("No micro-apps in the gallery yet.").foregroundStyle(.secondary)
            } else {
                PickerSearchField(text: $query, placeholder: "Search micro-apps",
                                  accessibilityLabel: "Search the Micro-app Gallery", palette: TingPickerStyle.palette)
                galleryResults(gallery.matching(query))
            }
            if let installError {
                Label(installError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Color.tingAmber).textSelection(.enabled)
            }
        } else if let catalogError {
            Label(catalogError, systemImage: "exclamationmark.triangle").foregroundStyle(Color.tingAmber)
        } else {
            ProgressView("Loading gallery…")
        }
    }

    private func galleryResults(_ listings: [MicroAppGallery.Listing]) -> some View {
        let localIDs = Set(model.microApps.map(\.bindingID))
        let localFiles = Set(model.microApps.map(\.file))
        return Group {
            if listings.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(listings) { listing in
                            VStack(alignment: .leading, spacing: 12) {
                                listingRow(listing, local: localIDs.contains(listing.id) || localFiles.contains(listing.fileName))
                                if listing.id != listings.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(query)
            }
        }
        .frame(height: 320)
    }

    private func listingRow(_ listing: MicroAppGallery.Listing, local: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(listing.title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(listing.description)
                Text("Data: \(listing.dataAccess)").foregroundStyle(.secondary)
                Text("Needs: \(listing.requirements)").foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if local {
                Text("Already local").foregroundStyle(.secondary)
            } else if !listing.supports(tingVersion: tingVersion) {
                Text("Needs Ting \(listing.minimumTingVersion) or newer").foregroundStyle(.secondary)
            } else if installing?.id == listing.id {
                ProgressView().controlSize(.small).accessibilityLabel("Installing \(listing.title)")
            } else {
                Button("Install") { installing = listing }
                    .accessibilityLabel("Install \(listing.title)")
                    .disabled(installing != nil)
            }
        }
    }

    private func load() async {
        gallery = nil
        catalogError = nil
        installError = nil
        do {
            let index = try await MicroAppGallerySource.index()
            try Task.checkCancellation()
            gallery = index
        } catch {
            guard !Task.isCancelled else { return }
            catalogError = "Could not load the gallery: \(error.localizedDescription)"
        }
    }

    private func install(_ listing: MicroAppGallery.Listing) async {
        installError = nil
        do {
            let data = try await MicroAppGallerySource.download(listing)
            try Task.checkCancellation()
            try model.installGalleryMicroApp(data, listing: listing)
            installed = listing
        } catch {
            guard !Task.isCancelled else { return }
            installError = "Could not install \(listing.title): \(error.localizedDescription)"
        }
        installing = nil
    }
}

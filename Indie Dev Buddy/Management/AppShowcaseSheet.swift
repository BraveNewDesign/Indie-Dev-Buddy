import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct AppShowcaseSheet: View {
    let apps: [AppRecord]
    let icons: [String: NSImage]

    @Environment(\.dismiss) private var dismiss
    @State private var settings: AppShowcaseSettings
    @State private var document: ShowcasePNG?
    @State private var exporting = false
    @State private var exportError: String?

    init(apps: [AppRecord], icons: [String: NSImage], identities: [IdentityRecord]) {
        self.apps = apps
        self.icons = icons
        var defaults = AppShowcaseSettings()
        defaults.selectedIDs = Set(apps.map(\.id))
        defaults.studio = AppShowcaseSettings.studioName(for: apps, identities: identities)
        if apps.count > defaults.capacity(for: .list) { defaults.layout = .grid }
        _settings = State(initialValue: defaults)
    }

    private var artwork: AppShowcaseArtwork {
        AppShowcaseArtwork(apps: settings.selection(from: apps), icons: icons, settings: settings)
    }

    private var capacity: Int { settings.capacity(for: settings.layout) }
    private var canExport: Bool { (1...capacity).contains(artwork.apps.count) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Share App Showcase").font(.title2.bold())
                Spacer()
                Text("\(Int(settings.format.pixelSize.width)) × \(Int(settings.format.pixelSize.height)) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(18)

            Divider()

            HStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.4))

                Divider()

                controls.frame(width: 300)
            }

            Divider()

            HStack {
                Button("Done", role: .cancel) { dismiss() }
                Spacer()
                ShareLink(
                    item: ShowcaseShareItem(render: { [artwork] in try artwork.pngData() }),
                    preview: SharePreview("App Showcase.png")
                ) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .disabled(!canExport)
                Button("Export PNG…", action: prepareExport)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
            .padding(16)
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 480, idealHeight: 625)
        .fileExporter(isPresented: $exporting, document: document, contentType: .png, defaultFilename: "App Showcase") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Couldn’t Export PNG", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @ViewBuilder private var preview: some View {
        if artwork.apps.isEmpty {
            ContentUnavailableView("Select Apps", systemImage: "square.grid.2x2",
                                   description: Text("Choose at least one app to preview your showcase."))
        } else if artwork.apps.count > capacity {
            let canSwitch = settings.layout == .list && artwork.apps.count <= settings.capacity(for: .grid)
            ContentUnavailableView {
                Label("Too Many Apps for This Layout", systemImage: "rectangle.inset.filled")
            } description: {
                Text("This layout fits up to \(capacity) apps at the selected size. Deselect apps or change the format or layout.")
            } actions: {
                if canSwitch {
                    Button("Switch to Grid") { settings.layout = .grid }
                }
            }
            .padding()
        } else {
            GeometryReader { geometry in
                let canvas = settings.format.canvas
                let scale = max(0.01, min(
                    (geometry.size.width - 44) / canvas.width,
                    (geometry.size.height - 44) / canvas.height
                ))
                artwork
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .scaleEffect(scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Showcase preview")
        }
    }

    private var controls: some View {
        Form {
            Section("Design") {
                Picker("Format", selection: $settings.format) {
                    ForEach(ShowcaseFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                Picker("Layout", selection: $settings.layout) {
                    ForEach(ShowcaseLayout.allCases, id: \.self) { Text($0.rawValue) }
                }
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(ShowcaseAppearance.allCases, id: \.self) { Text($0.rawValue) }
                }
            }

            Section("Content") {
                TextField("Heading", text: $settings.heading)
                TextField("Subtitle", text: $settings.subtitle, prompt: Text("Optional"))
                TextField("Studio", text: $settings.studio, prompt: Text("Optional"))
                Toggle("Platform indicators", isOn: $settings.showsPlatforms)
                Toggle("Indie Dev Buddy attribution", isOn: $settings.showsAttribution)
            }

            Section {
                HStack {
                    Button("Select All") { settings.selectedIDs = Set(apps.map(\.id)) }
                    Button("Clear") { settings.selectedIDs.removeAll() }
                        .disabled(settings.selectedIDs.isEmpty)
                }
                ForEach(apps) { app in
                    Toggle(isOn: Binding(
                        get: { settings.selectedIDs.contains(app.id) },
                        set: { included in
                            if included { settings.selectedIDs.insert(app.id) }
                            else { settings.selectedIDs.remove(app.id) }
                        }
                    )) {
                        HStack(spacing: 7) {
                            ShowcaseAppIcon(image: icons[app.id], size: 22)
                            Text(app.name).lineLimit(2)
                        }
                    }
                }
            } header: {
                Text("Apps (\(artwork.apps.count) selected)")
            }
        }
        .formStyle(.grouped)
    }

    private func prepareExport() {
        do {
            document = ShowcasePNG(data: try artwork.pngData())
            exporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct ShowcaseShareItem: Transferable {
    let render: @MainActor @Sendable () throws -> Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await item.render()
        }
        .suggestedFileName("App Showcase.png")
    }
}

private struct ShowcasePNG: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

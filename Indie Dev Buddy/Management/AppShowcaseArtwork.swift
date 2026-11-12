import AppKit
import CoreGraphics
import Foundation
import SwiftUI

nonisolated enum ShowcasePlatform: String, CaseIterable {
    case macOS, iOS, iPadOS, watchOS, tvOS, visionOS

    var symbol: String {
        switch self {
        case .macOS: "laptopcomputer"
        case .iOS: "iphone"
        case .iPadOS: "ipad"
        case .watchOS: "applewatch"
        case .tvOS: "appletv"
        case .visionOS: "visionpro"
        }
    }

    static func supported(by values: [String]) -> [Self] {
        let platforms = Set(values.compactMap { value -> Self? in
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "macos", "mac", "os x", "mac_os": .macOS
            case "ios", "iphone": .iOS
            case "ipados", "ipad": .iPadOS
            case "watchos", "apple watch", "watch_os": .watchOS
            case "tvos", "apple tv", "tv_os": .tvOS
            case "visionos", "vision_os": .visionOS
            default: nil
            }
        })
        return allCases.filter { platforms.contains($0) }
    }
}

nonisolated enum ShowcaseFormat: String, CaseIterable {
    case portrait = "Portrait 4:5"
    case square = "Square 1:1"
    case landscape = "Landscape 16:9"

    var pixelSize: CGSize {
        switch self {
        case .portrait: CGSize(width: 1080, height: 1350)
        case .square: CGSize(width: 1080, height: 1080)
        case .landscape: CGSize(width: 1920, height: 1080)
        }
    }

    var canvas: CGSize { CGSize(width: pixelSize.width / 2, height: pixelSize.height / 2) }
}

nonisolated enum ShowcaseLayout: String, CaseIterable {
    case list = "List"
    case grid = "Grid"
}

nonisolated enum ShowcaseAppearance: String, CaseIterable {
    case light = "Light"
    case dark = "Dark"
    case accent = "Soft Blue"
}

nonisolated struct AppShowcaseSettings {
    var format = ShowcaseFormat.portrait
    var layout = ShowcaseLayout.list
    var appearance = ShowcaseAppearance.light
    var heading = "My Apps"
    var subtitle = ""
    var studio = ""
    var selectedIDs: Set<String> = []
    var showsPlatforms = true
    var showsAttribution = true

    func selection(from apps: [AppRecord]) -> [AppRecord] {
        apps.filter { selectedIDs.contains($0.id) }
    }

    // Leave fixed space for the masthead, margins, and footer in every format.
    var collectionHeight: CGFloat { format.canvas.height - 216 }

    func columns(for count: Int, layout: ShowcaseLayout) -> Int {
        if layout == .list { return format == .landscape && count > 5 ? 2 : 1 }
        if count <= 4 { return max(1, count) }
        if count <= 10 { return format == .landscape ? 5 : 3 }
        if count <= 20 { return format == .landscape ? 7 : 4 }
        return format == .landscape ? 8 : 6
    }

    func capacity(for layout: ShowcaseLayout) -> Int {
        let columns = columns(for: Int.max, layout: layout)
        let minimumRowHeight: CGFloat = layout == .list ? 47 : 62
        return Int(collectionHeight / minimumRowHeight) * columns
    }

    static func studioName(for apps: [AppRecord], identities: [IdentityRecord]) -> String {
        guard let id = apps.first?.developerIdentityId,
              apps.allSatisfy({ $0.developerIdentityId == id }) else { return "" }
        return identities.first { $0.id == id }?.name ?? ""
    }
}

struct ShowcaseAppIcon: View {
    var image: NSImage?
    var size: CGFloat
    var tint: Color = .secondary

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                shape.fill(tint.opacity(0.12))
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.48, weight: .medium))
                            .foregroundStyle(tint)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

struct ShowcasePlatformSymbols: View {
    let platforms: [ShowcasePlatform]
    var spacing: CGFloat = 4

    var body: some View {
        if !platforms.isEmpty {
            HStack(spacing: spacing) {
                ForEach(platforms, id: \.self) { platform in
                    Image(systemName: platform.symbol)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(platforms.map(\.rawValue).joined(separator: ", "))
            .help(platforms.map(\.rawValue).joined(separator: ", "))
        }
    }
}

@MainActor
struct AppShowcaseArtwork: View {
    let apps: [AppRecord]
    let icons: [String: NSImage]
    let settings: AppShowcaseSettings

    private var canvas: CGSize { settings.format.canvas }
    private var dark: Bool { settings.appearance == .dark }
    private var ink: Color { dark ? Color(red: 0.96, green: 0.97, blue: 1) : Color(red: 0.10, green: 0.13, blue: 0.20) }
    private var secondaryInk: Color { dark ? Color(red: 0.72, green: 0.77, blue: 0.84) : Color(red: 0.34, green: 0.39, blue: 0.48) }
    private var paper: Color {
        switch settings.appearance {
        case .light: Color(red: 0.97, green: 0.97, blue: 0.96)
        case .dark: Color(red: 0.09, green: 0.11, blue: 0.16)
        case .accent: Color(red: 0.91, green: 0.95, blue: 0.99)
        }
    }

    private var columns: Int { settings.columns(for: apps.count, layout: settings.layout) }
    private var rowCount: Int { max(1, (apps.count + columns - 1) / columns) }
    private var rowHeight: CGFloat { settings.collectionHeight / CGFloat(rowCount) }
    private var columnWidth: CGFloat { (canvas.width - 80) / CGFloat(columns) }
    private var denseGrid: Bool { settings.layout == .grid && rowHeight < 100 }
    private var platformCount: Int {
        Set(apps.flatMap { ShowcasePlatform.supported(by: $0.platforms) }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
                .frame(height: 128, alignment: .topLeading)
            collection.frame(height: settings.collectionHeight)
            footer.frame(height: 23, alignment: .bottomLeading)
        }
        .padding(.horizontal, 40)
        .frame(width: canvas.width, height: canvas.height)
        .background {
            LinearGradient(colors: [paper, paper, dark ? Color(red: 0.13, green: 0.17, blue: 0.24) : .white],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .foregroundStyle(ink)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.dynamicTypeSize, .large)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !settings.studio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(settings.studio)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.7)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
            }
            Text(settings.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Apps" : settings.heading)
                .font(.system(size: 51, weight: .bold))
                .tracking(-2.3)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if !settings.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(settings.subtitle)
                    .font(.system(size: 17))
                    .foregroundStyle(secondaryInk)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.bottom, 14)
    }

    private var collection: some View {
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                let start = min(row * columns, apps.count)
                let end = min(start + columns, apps.count)
                HStack(spacing: 0) {
                    ForEach(apps[start..<end]) { app in
                        if settings.layout == .list {
                            listItem(app)
                                .frame(width: columnWidth, height: rowHeight)
                        } else {
                            gridItem(app)
                                .frame(width: columnWidth, height: rowHeight)
                        }
                    }
                    if settings.layout == .list, end - start < columns {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func listItem(_ app: AppRecord) -> some View {
        let size = min(apps.count == 1 ? 136 : 91, rowHeight - 9)
        return HStack(spacing: min(22, size * 0.24)) {
            ShowcaseAppIcon(image: icons[app.id], size: size, tint: secondaryInk)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: min(33, size * 0.38), weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if settings.showsPlatforms {
                    ShowcasePlatformSymbols(platforms: ShowcasePlatform.supported(by: app.platforms))
                        .font(.system(size: min(16, size * 0.27), weight: .medium))
                        .foregroundStyle(secondaryInk)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, columns > 1 ? 10 : 6)
    }

    private func gridItem(_ app: AppRecord) -> some View {
        let size = min(apps.count == 1 ? 170 : 112, columnWidth - 20, rowHeight - (denseGrid ? 34 : 53))
        return VStack(spacing: denseGrid ? 2 : 6) {
            ShowcaseAppIcon(image: icons[app.id], size: size, tint: secondaryInk)
            Text(app.name)
                .font(.system(size: denseGrid ? 9 : min(23, columnWidth * 0.12), weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if settings.showsPlatforms {
                ShowcasePlatformSymbols(platforms: ShowcasePlatform.supported(by: app.platforms),
                                        spacing: columnWidth < 100 ? 2 : 4)
                    .font(.system(size: denseGrid ? 7 : min(14, columnWidth * 0.105), weight: .medium))
                    .foregroundStyle(secondaryInk)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(apps.count == 1 ? "1 app" : "\(apps.count) apps")
            if settings.showsPlatforms, platformCount > 0 {
                Text("·")
                Text(platformCount == 1 ? "1 platform" : "\(platformCount) platforms")
            }
            Spacer()
            if settings.showsAttribution {
                Text("Made with Indie Dev Buddy")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(secondaryInk)
    }

    func pngData() throws -> Data {
        guard !apps.isEmpty, apps.count <= settings.capacity(for: settings.layout) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let renderer = ImageRenderer(content: self)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}

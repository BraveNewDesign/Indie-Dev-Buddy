import AppKit
import SwiftUI

struct AppLibraryRow: View {
    let app: AppRecord
    let iconRequest: WorkspaceThumbnailRequest?
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 14) {
            ShowcaseAppIcon(image: icon, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                if let description = app.description,
                   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    ShowcasePlatformSymbols(platforms: ShowcasePlatform.supported(by: app.platforms))
                    if let status = app.developmentStatus {
                        Text(status.label)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: iconRequest) {
            guard let iconRequest else { icon = nil; return }
            let image = await WorkspaceThumbnailCache.shared.load(iconRequest)
            guard !Task.isCancelled else { return }
            icon = image.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

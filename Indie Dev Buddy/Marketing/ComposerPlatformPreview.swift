import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ComposerPlatformPreview: View {
    let account: ComposerSocialAccount
    let resolvedText: String
    let avatarURL: URL?
    let mediaURLs: [URL]

    @ViewBuilder var body: some View {
        let platform = account.platform.lowercased()
        switch platform {
        case "threads": threadsPreview(account)
        case "instagram": instagramPreview(account)
        case "x", "twitter": xPreview(account)
        case "facebook": facebookPreview(account)
        case "linkedin": linkedInPreview(account)
        default: genericPreview(account)
        }
    }

    private func threadsPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                avatar(for: account, size: 38)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(account.handle ?? account.ownerName ?? "Account").font(.headline)
                        Text("· Threads").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(account.ownerName ?? "").font(.caption).foregroundStyle(.secondary)
                    postText
                    previewMedia(featured: false)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.secondary.opacity(0.16)))
    }

    private func instagramPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                avatar(for: account, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.handle ?? "Account").font(.subheadline.bold())
                    Text(account.ownerName ?? "").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            previewMedia(featured: true)
            Text(resolvedText.isEmpty ? "Your caption preview will appear here." : resolvedText)
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Text("Instagram preview · media shown from this account’s effective attachments")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.16)))
    }

    private func xPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                avatar(for: account, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(account.ownerName ?? account.handle ?? "Account").font(.headline)
                        if let handle = account.handle { Text(handle).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text("X").font(.headline)
                    }
                    postText
                    previewMedia(featured: false)
                }
            }
            Text("X post preview").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2)))
    }

    private func facebookPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                avatar(for: account, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.ownerName ?? account.handle ?? "Account").font(.subheadline.bold())
                    Text("\(account.handle ?? account.platform) · Facebook").font(.caption).foregroundStyle(.secondary)
                }
            }
            postText
            previewMedia(featured: false)
            Text("Facebook post preview").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.16)))
    }

    private func linkedInPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                avatar(for: account, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.ownerName ?? account.handle ?? "Account").font(.subheadline.bold())
                    Text("\(account.handle ?? account.platform) · LinkedIn").font(.caption).foregroundStyle(.secondary)
                    Text("Post").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            postText
            previewMedia(featured: false)
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(height: 3)
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.16)))
    }

    private func genericPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            accountHeader(account, size: 40)
            postText
            previewMedia(featured: false)
            Text("\(account.platform) preview").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.18)))
    }

    private var postText: some View {
        Text(resolvedText.isEmpty ? "Your post preview will appear here." : resolvedText)
            .font(.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    private func accountHeader(_ account: ComposerSocialAccount, size: CGFloat) -> some View {
        HStack(spacing: 10) {
            avatar(for: account, size: size)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.ownerName ?? "Account owner").font(.headline)
                Text(account.handle ?? account.profileURL?.host ?? account.platform)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(account.platform).font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func avatar(for account: ComposerSocialAccount, size: CGFloat) -> some View {
        if let avatarURL, let image = NSImage(contentsOf: avatarURL) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
                .accessibilityLabel("\(account.displayName) avatar")
        } else {
            Image(systemName: account.avatarSymbol)
                .font(.title3).foregroundStyle(.tint)
                .frame(width: size, height: size)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func previewMedia(featured: Bool) -> some View {
        let urls = mediaURLs
            .filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image)
            }
        if featured {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(urls, id: \.path) { url in
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 240, height: 220).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else if !urls.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(urls, id: \.path) { url in
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 100, height: 82).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
        }
    }
}

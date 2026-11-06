import SwiftUI

struct SocialPlatformIcon: View {
    let platform: String
    var size: CGFloat = 24

    static func assetName(for platform: String) -> String? {
        let normalized = platform
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        return switch normalized {
        case "facebook": "social-facebook"
        case "instagram": "social-instagram"
        case "linkedin": "social-linkedin"
        case "threads": "social-threads"
        case "x", "twitter": "social-x"
        default: nil
        }
    }

    private var assetName: String? { Self.assetName(for: platform) }

    var body: some View {
        Group {
            if let assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "at")
                    .font(.system(size: size * 0.72, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .accessibilityHidden(true)
    }
}

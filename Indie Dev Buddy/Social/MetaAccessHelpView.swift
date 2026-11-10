import SocialKit
import SwiftUI

struct MetaAccessHelpView: View {
    let platform: SocialPlatform

    private var providerName: String { platform.workspaceTitle }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    requirements
                    setupSteps
                    permissions
                    securityNote
                    officialGuides
                }
                .padding(24)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle("Set Up \(providerName) Access")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    @Environment(\.dismiss) private var dismiss

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect your account securely", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text(introText)
                .foregroundStyle(.secondary)
            Text("The Meta access token option is fully local and does not need an exchange service. Browser sign-in is optional and still requires one.")
                .font(.callout)
        }
    }

    private var requirements: some View {
        GroupBox("Before you start") {
            VStack(alignment: .leading, spacing: 8) {
                requirementRow("A Meta developer account", detail: "Sign in at developers.facebook.com with an account that can add your Facebook Page or professional profile as a test asset.")
                requirementRow("A Meta developer app", detail: "Create or select an app in Meta for Developers and add the product/use case for \(providerName). For personal testing, keep it in Development mode and add your own account as an app role or tester.")
                requirementRow("A user access token", detail: "Generate one in Meta's developer tools with the permissions Indie Dev Buddy needs. Paste the token into the secure field in the connection window; do not paste an App Secret.")
                if platform == .facebookPages {
                    requirementRow("The Facebook Page ID", detail: "Find the ID in the Page's settings or business tools. Indie Dev Buddy uses your user token to verify access and get the Page token.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set it up")
                .font(.headline)
            step(1, "Create or choose a Meta app", "Open Meta for Developers → My Apps. Create an app with the product/use case for \(providerName), or select one you manage. In Development mode, add your own account as an app role or tester where Meta asks.")
            step(2, "Enable the needed permissions", permissionSetup)
            step(3, "Generate a user access token", tokenSetup)
            step(4, "Verify and save it in Indie Dev Buddy", "Choose Connect \(providerName), leave the method set to Meta access token, paste the token, and click Verify and Save Token. For Facebook Pages, also enter the Page ID. The app checks the token with Meta, stores the resulting account credential in this Mac's Keychain, and sends posts directly from this Mac.")
            step(5, "Request broader access only if needed", "Development tokens are for your own app-role/test accounts. To let people outside your app's roles connect, request the required Advanced Access in Meta App Review. Meta may ask for business verification, a privacy policy, reviewer access, and a recording showing the feature.")
        }
    }

    private var permissions: some View {
        GroupBox("Permissions to grant in Meta") {
            VStack(alignment: .leading, spacing: 9) {
                Text(permissionSummary)
                    .font(.callout)
                Text("Only grant the permissions you need. Meta may limit a Development app to its own roles and test accounts; broader use can require Advanced Access and App Review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var securityNote: some View {
        Label {
            Text("Paste only the user access token. Never paste your Meta App Secret here. The access token is sent directly from Indie Dev Buddy to Meta and stored in this Mac's Keychain. Revoke it in Meta if you no longer trust this Mac or app.")
                .font(.callout)
        } icon: {
            Image(systemName: "key.horizontal.fill")
                .foregroundStyle(.orange)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var officialGuides: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meta's official guides")
                .font(.headline)
            Link("Open Meta for Developers", destination: URL(string: "https://developers.facebook.com/apps/")!)
            if platform == .facebookPages {
                Link("Open Graph API Explorer", destination: URL(string: "https://developers.facebook.com/tools/explorer/")!)
            }
            Link(destination: guideLink.url) {
                Label(guideLink.title, systemImage: "arrow.up.right.square")
            }
            Link("Meta App Review and permissions", destination: URL(string: "https://developers.facebook.com/docs/app-review/")!)
        }
    }

    private var introText: String {
        switch platform {
        case .facebookPages:
            "This connection publishes text to a Facebook Page you can manage. Personal Facebook profiles are not supported."
        case .instagram:
            "This connection uses Instagram Login and requires an Instagram Business or Creator account. Personal accounts cannot publish through this API."
        case .threads:
            "This connection uses Threads Login to publish to a Threads profile you control."
        default:
            "Follow these steps to connect your Meta account."
        }
    }

    private var permissionSummary: String {
        switch platform {
        case .facebookPages:
            "Needed: pages_show_list and pages_manage_posts for finding and publishing to a Page; pages_read_engagement and pages_read_user_content for reading Page activity; pages_manage_engagement for the supported comment and engagement actions."
        case .instagram:
            "Needed: instagram_business_basic to identify the professional profile, instagram_business_content_publish to publish media, and instagram_business_manage_comments for the supported comment actions."
        case .threads:
            "Needed: threads_basic to identify the profile, threads_content_publish to publish, threads_read_replies and threads_manage_replies for replies, and threads_delete for supported reply deletion."
        default:
            "Permissions depend on the selected provider."
        }
    }

    private var permissionSetup: String {
        switch platform {
        case .facebookPages:
            "For publishing, enable pages_show_list and pages_manage_posts. For reading Page posts and comments, also enable pages_read_engagement and pages_read_user_content. For the supported comment actions, add pages_manage_engagement."
        case .instagram:
            "Use Instagram Login with an Instagram Business or Creator account. Enable instagram_business_basic and instagram_business_content_publish. Add instagram_business_manage_comments if you also want the supported comment actions."
        case .threads:
            "Enable threads_basic and threads_content_publish. Add threads_read_replies, threads_manage_replies, and threads_delete only if you also need the corresponding reply actions."
        default:
            "Enable only the permissions needed for your account."
        }
    }

    private var tokenSetup: String {
        switch platform {
        case .facebookPages:
            "In Graph API Explorer, select your Meta app, choose Get User Access Token, select the permissions above, and generate a token. Paste the User token here, not a Page token; Indie Dev Buddy will verify your Page access and get the Page token itself."
        case .instagram:
            "In your app's Instagram API setup with Instagram Login, add your professional account and use Generate access tokens. Copy the Instagram User token. A linked Facebook Page is not required for this login method."
        case .threads:
            "In your app's Access the Threads API use case, add your account as a Threads tester and accept the invite in Threads. Then open Settings → User Token Generator, generate a token with the publishing permission, and copy it."
        default:
            "Generate an access token from Meta's developer tools."
        }
    }

    private var guideLink: (title: String, url: URL) {
        switch platform {
        case .facebookPages:
            return ("Facebook Pages API: get started", URL(string: "https://developers.facebook.com/docs/pages-api/getting-started/")!)
        case .instagram:
            return ("Instagram API with Instagram Login", URL(string: "https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/")!)
        case .threads:
            return ("Threads API: get started", URL(string: "https://developers.facebook.com/docs/threads/get-started/")!)
        default:
            return ("Meta for Developers", URL(string: "https://developers.facebook.com/")!)
        }
    }

    private func requirementRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SocialKit
import SwiftUI

struct MetaAccessHelpView: View {
    let platform: SocialPlatform
    let instagramAccessMethod: InstagramAccessMethod

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
            Text("Create or select a Meta developer app you manage. For your own accounts, use Development mode and add your account as a role or tester where Meta requires it.")
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
            step(2, "Set up Standard Access", "Open your use case’s Permissions and features screen. Add the permissions below for the features you plan to use. If a permission already shows Ready for testing, continue to token generation.")
            step(3, "Generate a user access token", tokenSetup)
            step(4, "Verify and save it in Indie Dev Buddy", "Choose Connect \(providerName), leave the method set to Meta access token, paste the token, and click Verify and Save Token. Enter the account or Page ID if the form requests it. The app checks the token with Meta, stores the resulting account credential in this Mac's Keychain, and sends posts directly from this Mac.")
            step(5, "Check Inbox and Performance", "Open Inbox to check comment access. In Performance, select a published post and click Refresh Post Insights. If you added a permission after generating your token, generate a fresh token with that permission and reconnect the same profile.")
        }
    }

    private var permissions: some View {
        GroupBox("Permissions to grant in Meta") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(permissionRows, id: \.title) { row in
                    requirementRow(row.title, detail: row.scopes)
                        .textSelection(.enabled)
                }
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
            if platform == .facebookPages || platform == .instagram && instagramAccessMethod == .facebookLogin {
                Link("Open Graph API Explorer", destination: URL(string: "https://developers.facebook.com/tools/explorer/")!)
                Link("Facebook long-lived tokens", destination: URL(string: "https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived/")!)
            }
            if platform == .threads {
                Link("Threads long-lived tokens", destination: URL(string: "https://developers.facebook.com/docs/threads/get-started/long-lived-tokens/")!)
            }
            Link(destination: guideLink.url) {
                Label(guideLink.title, systemImage: "arrow.up.right.square")
            }
        }
    }

    private var introText: String {
        switch platform {
        case .facebookPages:
            "This connection publishes text to a Facebook Page you can manage. Personal Facebook profiles are not supported."
        case .instagram:
            instagramAccessMethod == .facebookLogin
                ? "Connect a professional Instagram account linked to a Facebook Page you manage using a Facebook user token."
                : "Connect a professional Instagram account directly using an Instagram user token."
        case .threads:
            "This connection uses Threads Login to publish to a Threads profile you control."
        default:
            "Follow these steps to connect your Meta account."
        }
    }

    private var permissionRows: [(title: String, scopes: String)] {
        switch platform {
        case .facebookPages:
            [
                ("Find your Page and publish", "pages_show_list, pages_manage_posts"),
                ("Read Page posts", "pages_read_engagement"),
                ("Read visitor comments", "pages_read_engagement, pages_read_user_content"),
                ("Reply to comments", "pages_manage_engagement"),
                ("Post insights", "read_insights")
            ]
        case .instagram:
            instagramAccessMethod == .facebookLogin ? [
                ("Find your linked account", "pages_show_list, pages_read_engagement, instagram_basic. Meta may require business_management, ads_read, or ads_management for some roles."),
                ("Publish", "instagram_content_publish"),
                ("Read and reply to comments", "instagram_manage_comments"),
                ("Post insights", "instagram_manage_insights")
            ] : [
                ("Identify your account", "instagram_business_basic"),
                ("Publish", "instagram_business_content_publish"),
                ("Read and reply to comments", "instagram_business_manage_comments"),
                ("Post insights", "instagram_business_manage_insights")
            ]
        case .threads:
            [
                ("Identify your profile", "threads_basic"),
                ("Publish", "threads_content_publish"),
                ("Read replies", "threads_read_replies"),
                ("Reply and manage replies", "threads_content_publish, threads_manage_replies"),
                ("Post insights", "threads_manage_insights"),
                ("Delete your replies", "threads_delete")
            ]
        default:
            []
        }
    }

    private var tokenSetup: String {
        switch platform {
        case .facebookPages:
            "In Graph API Explorer, select your Meta app, choose Get User Access Token, select the permissions above, and generate a token. Use Meta’s long-lived user token guide to extend that token before importing it. Indie Dev Buddy verifies access and saves both the selected Page token and the source user grant in this Mac’s Keychain so it can recover the Page token when the grant is valid."
        case .instagram:
            instagramAccessMethod == .facebookLogin
                ? "In Graph API Explorer, select your Meta app and generate a Facebook user token. Then look up your linked Instagram ID with GET /me/accounts?fields=id,name,instagram_business_account{id}. Use the nested instagram_business_account.id, which is separate from the Facebook Page ID. Indie Dev Buddy reads the token’s granted permissions from Meta."
                : "In your Meta app’s Instagram API setup with Instagram Login, add your professional account and generate an Instagram user access token. Paste it into the Instagram Login connection form."
        case .threads:
            "In your app's Access the Threads API use case, add your account as a Threads tester and accept the invite in Threads. Then open Settings → User Token Generator, generate a token with the permissions for the features you selected. Use the Threads long-lived token guide to exchange a short-lived token outside Indie Dev Buddy and import only the resulting access token."
        default:
            "Generate an access token from Meta's developer tools."
        }
    }

    private var guideLink: (title: String, url: URL) {
        switch platform {
        case .facebookPages:
            return ("Facebook Pages API: get started", URL(string: "https://developers.facebook.com/docs/pages-api/getting-started/")!)
        case .instagram:
            return instagramAccessMethod == .facebookLogin
                ? ("Instagram API with Facebook Login", URL(string: "https://developers.facebook.com/docs/instagram-platform/instagram-api-with-facebook-login/get-started/")!)
                : ("Instagram API with Instagram Login", URL(string: "https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/")!)
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

---
title: Social Connections
nav_order: 3
permalink: /social-connections/
---

# Social connections and local delivery

In **Websites & Social Accounts → Social Accounts**, choose a provider, connect the intended remote account, then save the workspace account. The editor can prefill the account's display name, handle, and profile URL from SocialKit; these remain editable profile metadata. The verified provider identity (platform, server, and remote ID) is stored separately and is the recipient key for API delivery. It contains no credentials. A saved workspace avatar is used in account and composer previews. **View Account Activity** lists the posts, comments, and actions that connection can access; author and reply context is shown only when the provider returns it, and actions depend on the account's granted capabilities. **Unlink from This Workspace Account** removes the mapping when saved. Provider tokens are managed in the Mac’s Keychain. Unlinking a workspace record leaves the stored credential available to other workspace records using that account.

In the composer, choose **Scheduled on This Mac** for local API delivery or **Manually Scheduled** for a date you plan to handle yourself. Indie Dev Buddy must be running and the Mac awake when a post is due. Before delivery, the app checks stored credentials and stops if it knows the connection needs authorization. It also checks Meta connections on launch, on wake, and periodically while the Mac is awake. Account settings and the schedule editor show known expiry and reconnect status. Review missed or uncertain attempts in the composer’s API Delivery History. A saved API schedule keeps an immutable snapshot of its approved text, resolved mentions, recipient, media, and time. Draft edits do not alter it. Choose **Reschedule with Current Draft** to replace the scheduled intent with the current version and a new future time or media link. Delivery errors that could follow a provider write are marked uncertain and require checking the account before another attempt. The workspace’s saved delivery state and receipt appear in the content library once the app records the result. The workspace JSON and CLI alone cannot authorize delivery; the app's device-local journal is required.

For Instagram and Threads, the local journal stores the staged container ID with the approved delivery. If the app closes before the publish request starts, the app can resume polling the same container after relaunch, while the Mac is awake, for up to 24 hours. Once a publish request may have reached Meta, the app only checks container status. A confirmed publication can appear in delivery history without a post ID or link.

| Provider | Connect using | Local API schedule |
| --- | --- | --- |
| Bluesky | Handle, app password, and trusted HTTPS server | Text |
| Facebook Pages | Facebook user access token and Page ID | Text or one hosted HTTPS photo on the authorized Page |
| Threads | Threads user access token for each Threads profile | Text or one explicit public HTTPS image/video |
| Instagram | Facebook user access token, linked Page, and Instagram professional account ID | One explicit public HTTPS image/video, with an optional caption |
| X | Public client ID and registered callback with OAuth 2.0 authorization code flow | Text |
| LinkedIn | Public client ID, registered HTTPS callback, trusted exchange service, and optional organization URN | Text |
| Mastodon | Trusted HTTPS server and callback. The connection dialog suggests the app’s custom callback. | Text |
| GitHub | Manual account metadata and scheduling only; no provider API connection. | Text |
| Other accounts | Workspace account metadata | Manual |

Provider account permissions determine what works in the signed app. The Facebook Pages, Threads, and Instagram composer accepts a public HTTPS media link without embedded credentials, query parameters, or fragments. Enter a single image for Facebook Pages. The provider fetches the file from its URL. Provider-held Facebook Page scheduling requires live validation of creation, status, and cancellation with the configured Meta app.

Bluesky @mentions can be resolved from the composer against the connected account’s PDS. The scheduled payload keeps each resolved DID and UTF-8 byte range, so a later handle change cannot redirect the mention. Other providers currently receive @names as plain text. An inbound mentions inbox is a separate feature and is not part of this Activity view. LinkedIn can optionally request Community Management feed scopes during connection; LinkedIn must approve the app and grant those scopes before comments and posts become available.


### Bring your own image storage

Open **Settings → Image Hosting** and enter the Cloudflare account ID, R2 bucket name, and S3 access keys. Create an Object Read & Write token scoped to that bucket. Keep the bucket private and configure an R2 lifecycle rule to expire objects under `indie-dev-buddy/` after one day. Storage usage is billed to the bucket owner. [R2 lifecycle rules](https://developers.cloudflare.com/r2/buckets/object-lifecycles/)

Attach one image and choose **Publish Now** on Instagram or Threads. Indie Dev Buddy uploads a JPEG copy to your bucket and gives Meta a download URL that expires after one hour. Settings are stored in the Mac’s Keychain. **Disconnect** removes the saved credentials from the Mac. The bucket’s lifecycle rule removes uploaded objects. For API schedules, enter an existing HTTPS media URL in the composer.

## Meta token lifetime

### Facebook Pages

1. Open **Social Accounts**, add **Facebook Pages**, and choose **Meta access token**. In [Graph API Explorer](https://developers.facebook.com/tools/explorer/), select the Indie Dev Buddy app, choose **User Token**, and request `pages_show_list`. Add `pages_manage_posts` to publish text. Add `pages_read_engagement` for reading Page posts; add `pages_read_user_content` and `pages_manage_engagement` only for the comment actions you need. Generate a fresh token and approve access to the Page.
2. Paste the **Facebook user token** and enter the Facebook **Page ID**. Choose **Verify and Save Token**. Indie Dev Buddy reads the authorized Pages, obtains the Page token for the selected ID, checks the Page identity, and saves the Page token and source user grant in Keychain. The Page must grant the user the `CREATE_CONTENT` task for publishing.

### Instagram: Facebook Login (Page token)

This is the route used by the current Indie Dev Buddy connection form. It accepts a Facebook **User Token**, discovers the linked Page, then uses that Page's token for Instagram. Meta calls the route **API setup with Facebook login**; its dashboard marks it as legacy but still supported. The newer **Unified Login** configuration uses a system-user token and is not the token type this connection form accepts.

1. In Meta for Developers, open **Use cases → Instagram API → Customize → API setup with Facebook login**. Click **Add required content permissions**. This adds the Facebook Login Instagram scopes to the app.
2. Open **Permissions and features** for the Instagram API use case. If your Facebook Page role was granted through Meta Business Manager, click **Add** next to `ads_read` (preferred) or `ads_management`. If a permission is absent from Graph API Explorer, add it here first, then reload Explorer. Meta's [Page permission requirements](https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/page) explain when an ads permission is needed for Business Manager roles.
3. In [Graph API Explorer](https://developers.facebook.com/tools/explorer/), select the Indie Dev Buddy app and **User Token**. Request `pages_show_list`, `pages_read_engagement`, `instagram_basic`, and `instagram_content_publish`; add `business_management` if Meta's setup requires it. Add `instagram_manage_comments` only if you need comment actions. Generate a new token after changing permissions and approve access with the Facebook user who can manage the linked Page.
4. To check the grants, select **GET** as the method and enter only `/me/permissions` in the path field. Do not type `GET` in the path. Confirm the required scopes show `granted`. To check the account/Page link, request `/me/accounts?fields=id,name,tasks,instagram_business_account{id}`. Confirm the returned Page has `CREATE_CONTENT` and that its `instagram_business_account.id` matches the Instagram professional account ID. The Facebook Page ID and Instagram account ID are different.
5. In Indie Dev Buddy, add **Instagram**, choose **Meta access token → Facebook Login (Page token)**, enter the Instagram professional account ID, and paste the Facebook user token. Leave the optional permissions field blank; the app reads grants from Meta. Click **Verify and Save Token**. It retrieves the linked Page token itself; do not paste a Page token in the Facebook user token field.

For example, the Brave New Design account `@bravenewdesignofficial` has Instagram account ID `17841469532626741`. Use the ID shown by the Page lookup for other accounts. A personal Instagram account cannot use this publishing route; use an Instagram Business or Creator account linked to a Facebook Page.

Meta documents both [Facebook Login setup](https://developers.facebook.com/docs/instagram-platform/instagram-api-with-facebook-login/get-started/) and [the Unified Login setup](https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-unified-login/). Keep the selected login method and token type aligned.

### Threads

1. In Meta for Developers, open an app with **Access the Threads API**. For development access, add each Threads profile as a tester and accept the invite in Threads. Generate a Threads user token for that profile from **Use cases → Access the Threads API → Customize → Settings → User Token Generator**.
2. Request `threads_basic` to identify/read the profile. Add `threads_content_publish` to publish; add `threads_read_replies`, `threads_manage_replies`, and `threads_delete` only for those reply actions. Generate a fresh token after changing grants.
3. In Indie Dev Buddy, add **Threads**, choose **Meta access token**, paste that profile's Threads user token, and click **Verify and Save Token**. Repeat for the other Threads profile. Threads does not use a Facebook Page ID or Instagram account ID.

Meta's [Threads app setup](https://developers.facebook.com/docs/threads/get-started/create-an-app/) and [Threads API docs](https://developers.facebook.com/documentation/threads/) describe the tester and token flows.

### Token storage and renewal

The app stores the verified provider credential in the Mac’s Keychain. For Facebook Pages and Instagram Facebook Login, the Page token and source Facebook user grant are saved separately in the same credential record; the app can use the source grant to recover that same Page token while the grant is valid. For Threads and the separate Instagram Login option, mark a token long-lived only when Meta confirms that it is. The app waits at least 24 hours after import before using the provider’s renewal endpoint. A known expired token requires reconnection. Unknown expiry stays unknown unless the provider returns a lifetime. A short-lived token exchange that needs an app secret must happen outside Indie Dev Buddy or on a configured confidential broker. Never paste tokens into chat, source files, or logs.

Unlinking a workspace record leaves its Keychain credential available to other workspace records that may share that connection. To revoke provider access, revoke the app grant in Meta separately.

## Browser and broker setup

Meta access token import works with the default build and connects directly to Meta. Browser sign-in is an optional deployment for owners who control the callback domain and operate a trusted exchange service.

1. Enable Associated Domains for the signing identifier and provision the target with the capability. Build the app with `INDIE_DEV_BUDDY_ENTITLEMENTS=Indie Dev Buddy OAuth.entitlements` and set `INDIE_DEV_BUDDY_OAUTH_CALLBACK_HOST` to the owner-controlled fully qualified hostname. Pass these as Xcode build setting overrides. The opt-in entitlement file preserves Keychain access and adds `webcredentials:<callback-host>`. Verify the final app's signed entitlements with `codesign -d --entitlements :-`.
2. Serve `https://<callback-host>/.well-known/apple-app-site-association` as JSON over HTTPS without redirects. Use the signed app's application identifier (including its app ID prefix) as the value in `{"webcredentials":{"apps":["<signed-application-identifier>"]}}`. Verify Apple's association has propagated and test on the signed app. [Apple's Associated Domains setup](https://developer.apple.com/documentation/xcode/supporting-associated-domains), [AuthenticationServices HTTPS callback](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https(host:path:)).
3. Register the exact HTTPS callback, including path and any trailing slash, with each Meta login product. Enter that URL and the public app ID in Indie Dev Buddy. Set up separate allowlisted registrations for Facebook Login for Pages, Instagram API with Instagram Login, Instagram API with Facebook Login, and the Threads API. The current Instagram Facebook Login token-import flow is configured separately in the app and does not use this broker. The app's custom scheme remains available to providers that accept it. Meta uses the confidential authorization-code flow and does not receive PKCE parameters in this app. The provider references did not establish S256 PKCE support for these exact login products and configured registrations. [Facebook manual login](https://developers.facebook.com/docs/facebook-login/guides/advanced/manual-flow/), [Instagram business login](https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/business-login/), [Instagram Facebook Login setup](https://developers.facebook.com/docs/instagram-platform/instagram-api-with-facebook-login/get-started/), [Meta's Threads API collection](https://www.postman.com/meta/threads/documentation/dht3nzz/threads-api).
4. Enter the trusted exchange service's HTTPS base URL and a temporary service bearer credential. Only public registration values are saved by the connection dialog. Keep Meta app secrets on the broker, and keep authorization payloads, tokens and service credentials out of access and error logs, including at the callback host.

### Meta broker contract

Both routes take JSON via HTTPS without redirects, require `Authorization: Bearer <service credential>`, and return JSON. Authenticate and authorize the operator on each request. Use `Cache-Control: no-store` on the responses.

- `POST <base URL>/oauth/session` receives `platform` (`facebookPages`, `instagram`, or `threads`), `client_id`, `redirect_uri`, and `state`. Validate the provider, app ID and exact redirect against server-side configuration. Bind the values to the authenticated operator and a short-lived server session. Return `{"session_id":"<random opaque base64url identifier>"}` before the app opens the browser. Expire abandoned sessions.
- `POST <base URL>/oauth/exchange` receives `platform`, `redirect_uri`, `state`, `session_id`, and the callback `code`. Indie Dev Buddy checks the callback's exact URL and state before sending the request. Verify the operator, provider, exact redirect, state, session expiry, and server-side app ID binding. Atomically consume the session and reject reuse of the same provider authorization code before making a single provider exchange attempt. Use the bound server-side app registration for the exchange. Return `access_token` and any provider-confirmed ISO 8601 `expires_at` and `granted_scopes` array. For a verified Instagram or Threads long-lived token, include ISO 8601 `meta_long_lived_refresh_eligible_at` if known. Supply eligibility using that product's documented rules. If an exchange or delivery of the response is uncertain, require a fresh browser attempt.

LinkedIn retains its existing single `POST <base URL>/oauth/exchange` contract with `platform`, `code`, and `redirect_uri`. It requires provider-verified `granted_scopes`, and may return `refresh_token` and ISO 8601 `expires_at`. Reconnect when the LinkedIn token expires. SocialKit's standalone Meta validation app also keeps its separate development exchange and refresh bridge.

Validate browser sign-in end to end with the signed app, the real AASA and broker, and the configured Meta products, permissions, and designated test accounts. Browser sign-in remains unavailable in the default build.

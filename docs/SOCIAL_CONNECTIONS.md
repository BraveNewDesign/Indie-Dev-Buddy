# Social connections and local delivery

In **Websites & Social Accounts → Social Accounts**, choose a provider, connect the intended remote account, then save the workspace account. The editor displays the account returned by SocialKit. **View Account Activity** lists the posts, comments, and actions that connection can access. **Unlink from This Workspace Account** removes the mapping when saved. Provider tokens are managed in the Mac’s Keychain. Unlinking a workspace record leaves the stored credential available to other workspace records using that account.

In the composer, choose **Scheduled** for API delivery or **Manually Scheduled** for a date you plan to handle yourself. Indie Dev Buddy must be running and the Mac awake when a post is due. Review missed or uncertain attempts in the composer’s API Delivery History. Changes to an approved delivery require a new future time or media link to create a new intent. An edit to the draft alone leaves the approved text intact. The workspace’s saved delivery state and receipt appear in the content library once the app records the result.

| Provider | Connect using | Local API schedule |
| --- | --- | --- |
| Bluesky | Handle, app password, and trusted HTTPS server | Text |
| Facebook Pages | Meta app ID, registered HTTPS callback, Page ID, and trusted exchange service | Text on the authorized Page |
| Threads | Threads app ID, registered HTTPS callback, and trusted exchange service | Text or one explicit public HTTPS image/video |
| Instagram | Instagram app ID, professional account, registered HTTPS callback, and trusted exchange service | One explicit public HTTPS image/video, with an optional caption |
| X | Public client ID and registered callback with OAuth 2.0 authorization code flow | Text |
| LinkedIn | Public client ID, registered HTTPS callback, trusted exchange service, and optional organization URN | Text |
| Mastodon | Trusted HTTPS server and callback. The connection dialog suggests the app’s custom callback. | Text |
| Other accounts | Workspace account metadata | Manual |

Provider account permissions determine what works in the signed app. Local workspace attachments are never uploaded automatically. The Threads and Instagram composer accepts a plain public HTTPS media link without embedded credentials, query parameters, or fragments. This workflow uses a single hosted item per destination.

Bluesky @mentions can be resolved from the composer against the connected account’s PDS. The scheduled payload keeps each resolved DID and UTF-8 byte range, so a later handle change cannot redirect the mention. Other providers currently receive @names as plain text. An inbound mentions inbox is a separate feature and is not part of this Activity view. LinkedIn can optionally request Community Management feed scopes during connection; LinkedIn must approve the app and grant those scopes before comments and posts become available.

## Browser and broker setup

For an HTTPS callback, the signed Indie Dev Buddy build needs the matching `webcredentials:<callback-host>` Associated Domains entitlement. The callback host needs an Apple App Site Association file authorizing the signed Indie Dev Buddy application identifier in `webcredentials.apps`. Register the exact callback, including path and trailing slash, with the provider. Enter that same URL in Indie Dev Buddy. The app also registers the custom scheme `com.bravenewdesign.indiedevbuddy.oauth` for providers that accept it.

The Meta and LinkedIn connection dialogs accept the base URL of a trusted service and a masked bearer credential for that service. The provider App Secret belongs on the service. The Mac keeps the bearer credential in memory during connection and stores only the public provider registration values locally. Use a service you control and authenticate and authorize the operator before performing any exchange. Allowlist the provider and exact redirect, exchange each code only once, and keep credentials and OAuth payloads out of access and error logs.

The client calls `POST <base URL>/oauth/exchange` with `Authorization: Bearer <service credential>` and a JSON body containing `platform`, `code`, and `redirect_uri`. Supported broker platform values are `facebookPages`, `threads`, `instagram`, and `linkedIn`. Return JSON with `access_token` and, when applicable, `refresh_token`, ISO 8601 `expires_at`, and provider-verified `granted_scopes` as a string array. LinkedIn requires `granted_scopes`; requested scopes are not treated as proof of access. Serve the endpoint over HTTPS without redirects. LinkedIn connections use the broker only during authorization. Reconnect in the app when a LinkedIn token expires.

Live acceptance needs the provider registration, permissions, signed callback setup, a real broker for confidential flows, and a designated account for each publishing check.

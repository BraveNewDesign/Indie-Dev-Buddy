---
title: Advanced OAuth Broker Setup
nav_order: 8
permalink: /oauth-broker/
---

# Advanced OAuth broker setup

This optional deployment guide is for developers who control the callback domain and operate a trusted token exchange service. Browser sign-in is unavailable in the default build; Meta access-token import works without this service. The broker keeps provider app secrets off the user's Mac.

## Meta setup for comments and insights

Browser sign-in requests `read_insights` for Facebook Pages, `instagram_business_manage_insights` for direct Instagram Login, `instagram_manage_insights` for Instagram with Facebook Login, and `threads_manage_insights` for Threads. Existing connections need fresh authorization to pick up newly requested scopes.

Set up Standard Access for `pages_read_user_content` in the Meta app’s Pages use case before testing Facebook comments. Facebook Pages also needs `pages_read_engagement` to read comments and `pages_manage_engagement` to reply. Validate each operation with a role account before requesting public access.

When connecting accounts for other businesses, review the use case’s business-use model in Meta’s App Dashboard and request Advanced Access for the required scopes. Complete the privacy policy and data deletion settings, verify the contact email, and check the Business Verification and App Review requirements. Add redirect URIs only for callback services that are deployed and verified.

## Browser and broker setup

Meta access token import works with the default build and connects directly to Meta. Browser sign-in is an optional deployment for owners who control the callback domain and operate a trusted exchange service.

1. Enable Associated Domains for the signing identifier and provision the target with the capability. Build the app with `INDIE_DEV_BUDDY_ENTITLEMENTS=Indie Dev Buddy OAuth.entitlements` and set `INDIE_DEV_BUDDY_OAUTH_CALLBACK_HOST` to the owner-controlled fully qualified hostname. Pass these as Xcode build setting overrides. The opt-in entitlement file preserves Keychain access and adds `webcredentials:<callback-host>`. Verify the final app's signed entitlements with `codesign -d --entitlements :-`.
2. Serve `https://<callback-host>/.well-known/apple-app-site-association` as JSON over HTTPS without redirects. Use the signed app's application identifier (including its app ID prefix) as the value in `{"webcredentials":{"apps":["<signed-application-identifier>"]}}`. Verify Apple's association has propagated and test on the signed app. [Apple's Associated Domains setup](https://developer.apple.com/documentation/xcode/supporting-associated-domains), [AuthenticationServices HTTPS callback](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https(host:path:)).
3. Register the exact HTTPS callback, including path and any trailing slash, with each Meta login product. Enter that URL and the public app ID in Indie Dev Buddy. Facebook Pages and Instagram with Facebook Login can use the same Facebook registration and exact redirect. Threads and legacy direct Instagram Login use their own registrations. The Instagram Facebook Login flow needs a professional Instagram account linked to a Page that grants you content access. The app's custom scheme remains available to providers that accept it. Meta uses the confidential authorization-code flow and does not receive PKCE parameters in this app. The provider references did not establish S256 PKCE support for these exact login products and configured registrations. [Facebook manual login](https://developers.facebook.com/docs/facebook-login/guides/advanced/manual-flow/), [Instagram business login](https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/business-login/), [Instagram Facebook Login setup](https://developers.facebook.com/docs/instagram-platform/instagram-api-with-facebook-login/get-started/), [Meta's Threads API collection](https://www.postman.com/meta/threads/documentation/dht3nzz/threads-api).
4. Enter the trusted exchange service's HTTPS base URL and a temporary service bearer credential. Public registration values are saved per account. Users can opt in to remembering the service bearer in Keychain for that account and exact endpoint. Keep Meta app secrets on the broker, and keep authorization payloads, tokens and service credentials out of access and error logs, including at the callback host.

### Meta broker contract

Both routes take JSON via HTTPS without redirects, require `Authorization: Bearer <service credential>`, and return JSON. Authenticate and authorize the operator on each request. Use `Cache-Control: no-store` on the responses.

- `POST <base URL>/oauth/session` receives `platform` (`facebookPages`, `instagram`, or `threads`), `client_id`, `redirect_uri`, and `state`. Validate the provider, app ID and exact redirect against server-side configuration. Bind the values to the authenticated operator and a short-lived server session. Return `{"session_id":"<random opaque base64url identifier>"}` before the app opens the browser. Expire abandoned sessions.
- `POST <base URL>/oauth/exchange` receives `platform`, `redirect_uri`, `state`, `session_id`, and the callback `code`. Indie Dev Buddy checks the callback's exact URL and state before sending the request. Verify the operator, provider, exact redirect, state, session expiry, and server-side app ID binding. Atomically consume the session and reject reuse of the same provider authorization code before making a single provider exchange attempt. Use the bound server-side app registration for the exchange. Return `access_token` and any provider-confirmed ISO 8601 `expires_at` and `granted_scopes` array. For a verified Instagram or Threads long-lived token, include ISO 8601 `meta_long_lived_refresh_eligible_at` if known. Supply eligibility using that product's documented rules. If an exchange or delivery of the response is uncertain, require a fresh browser attempt.

LinkedIn retains its existing single `POST <base URL>/oauth/exchange` contract with `platform`, `code`, and `redirect_uri`. It requires provider-verified `granted_scopes`, and may return `refresh_token` and ISO 8601 `expires_at`. Reconnect when the LinkedIn token expires. SocialKit's standalone Meta validation app also keeps its separate development exchange and refresh bridge.

Validate browser sign-in end to end with the signed app, the real AASA and broker, and the configured Meta products, permissions, and designated test accounts. Browser sign-in remains unavailable in the default build.


### Optional LinkedIn refresh

A LinkedIn broker can implement `POST /oauth/refresh` for connections that receive a refresh token. The app uses the remembered service bearer and sends a JSON body with `platform` and `refresh_token`. The service should verify the caller and use the LinkedIn app registration that issued the grant. Return JSON with `access_token` and, when provided by LinkedIn, `refresh_token`, `expires_at` as an ISO 8601 timestamp, and `granted_scopes`. A broker without a refresh route can return HTTP 404 or 405. Users can continue using the saved access token until fresh authorization is required.

### Private Meta broker on Netlify

The [oauth-broker directory](../oauth-broker/) implements registration discovery and the Meta session/exchange contract for Facebook Pages, Instagram Login, and Threads. It uses a dedicated Netlify project with `oauth-broker` as its deploy directory. The static publish directory only contains the callback fallback and Apple association file. The broker exchanges the authorization code and requests the provider’s long-lived user token. Indie Dev Buddy checks the granted scopes with Meta and stores its Page credential and source grant in Keychain.

1. From `oauth-broker`, run `npm ci` and `npm test`. Deploy to the dedicated Netlify project.
2. In that project's environment settings, set `META_FACEBOOK_APP_ID`, `META_FACEBOOK_APP_SECRET`, and `IDB_BROKER_CREDENTIAL` for production function runtime. Treat the last two as secrets. Use a randomly generated bearer of at least 32 characters for `IDB_BROKER_CREDENTIAL` and enter the same value in the app's **Trusted Exchange Service** field. Redeploy after adding or rotating these values.
3. Add `connect.bravenewdesign.com` to the broker project and verify HTTPS and the exact association-file URL. Verify the application identifier in the association file against the entitlements of the build you sign.
4. Add `https://connect.bravenewdesign.com/oauth/callback/facebook` to the Meta app's valid OAuth redirect URIs. Configure Indie Dev Buddy with the app ID, exact callback and `https://connect.bravenewdesign.com` as the exchange service base URL. Test with a designated role account.

The broker uses strong-consistency reads and conditional writes for one-time session and code claims. Stored claims contain hashes and expiry timestamps. A scheduled function prunes expired claims. If an exchange fails after the claim, restart authorization from Indie Dev Buddy. For the Brave New Design setup, connect Instagram through Facebook Login using the Facebook app ID, secret, and callback already configured on the broker. In the Meta dashboard, make sure the Page and professional Instagram account are linked and available to your role. To enable Threads or a Meta app that still supports direct Instagram Login, add the product-specific credentials below and redeploy. Store each app secret as a Production secret.

| Provider | Netlify variables | Exact callback |
| --- | --- | --- |
| Instagram API with Instagram Login | `META_INSTAGRAM_APP_ID`, `META_INSTAGRAM_APP_SECRET` | `https://connect.bravenewdesign.com/oauth/callback/instagram` |
| Threads | `META_THREADS_APP_ID`, `META_THREADS_APP_SECRET` | `https://connect.bravenewdesign.com/oauth/callback/threads` |

All three providers share the same `IDB_BROKER_CREDENTIAL`. A build signed for the hosted domain uses Facebook Login for Facebook Pages and linked Instagram accounts and looks up the Threads registration from the broker. Remembering the broker password makes it available to the other hosted Meta connections on this Mac. For a custom registration that uses direct Instagram Login, leave **Use Facebook Login for Instagram** off and use the direct Instagram callback.

For a private deployment on another domain, set `IDB_CALLBACK_ORIGIN` to your HTTPS origin, update the shipped association file to match your signing identifier, and sign the app with your domain entitlement. In the app, set your own broker URL and exact provider callback. Leave the app ID blank to load it from this broker, or enter it for a broker that only implements the original session/exchange contract.

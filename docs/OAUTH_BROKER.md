---
title: Advanced OAuth Broker Setup
nav_order: 8
permalink: /oauth-broker/
---

# Advanced OAuth broker setup

This optional deployment guide is for developers who control the callback domain and operate a trusted token exchange service. Browser sign-in is unavailable in the default build; Meta access-token import works without this service. The broker keeps provider app secrets off the user's Mac.

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

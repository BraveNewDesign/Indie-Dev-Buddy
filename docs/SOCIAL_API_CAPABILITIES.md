# Social API capabilities for Inbox and Performance

Research checked November 19, 2026 against provider documentation and the checked-in [SocialKit package pin](../Indie%20Dev%20Buddy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) (`66a78ca78b87fe225a2917a9c15f3d9acf11da5d`). This is a source review. Production app approval, account grants, endpoint responses, and billing were not tested against live accounts. The inventory covers the seven social APIs in [SocialConnections.swift](../Indie%20Dev%20Buddy/Social/SocialConnections.swift). GitHub and other manual accounts have no integrated social API.

## Current Indie Dev Buddy integration

All seven providers have post-list and post-lookup routes. Account Activity checks capabilities before offering actions. The pinned SDK's common `SocialPost` carries an optional `likeCount`, media, and optional author, parent, root and ownership fields. It has no general insights payload. Account Activity does not display a metrics table, collect an account-wide comment inbox, or sync comment history in the background.

| Provider | Current app path for incoming comments and replies | Current count in the SDK post model |
| --- | --- | --- |
| Bluesky | App facade explicitly rejects reply reads and writes | Like count when available |
| Facebook Pages | Page post comments and reply writes, subject to Page grants | Optional count through Meta post mapping |
| Threads | Post `/replies` and reply writes. The adapter does not use `/conversation` | No dedicated insights request |
| Instagram | Media `/comments`; replies to selected comments. Nested replies are absent from the current view | Media like count when returned |
| X | Recent search by conversation ID and reply creation, subject to app access | Like count from `public_metrics`; additional public metrics are not mapped |
| LinkedIn | Social actions through optional feed access; organization and member permissions differ | Normalized post like count is unset |
| Mastodon | App facade explicitly rejects reply reads and writes | Favourites mapped to like count |

The SDK uses Threads v1.0, Instagram Graph v27.0, LinkedIn Marketing version 202610, and X API v2 in the inspected adapters. Recheck versions, scopes, and response models when changing the package pin. See [connection setup](SOCIAL_CONNECTIONS.md) for supported login paths.

## Upstream capabilities and implementation gaps

### Bluesky

- **Inbox.** `app.bsky.feed.getAuthorFeed` lists authored content. `app.bsky.feed.getPostThread` supplies visible thread context, and authenticated `app.bsky.notification.listNotifications` can seed recent reply and mention activity. To reply, publish an `app.bsky.feed.post` record with strong references (URI and CID) to its root and parent. Allow for blocked, missing, or depth-limited nodes.
- **Performance.** The AppView post view includes optional counts for likes, replies, reposts and quotes. The post-view schema supplies no views, reach, impressions or link-click counts.
- **Gap.** Add SDK conversation and reply support behind the app facade. Use DIDs and AT URIs for identity and deduplication. Confirm notification scope and completeness for the currently supported sign-in path.

Sources: [HTTP API reference](https://docs.bsky.app/docs/api/app-bsky-feed-get-post-thread), [notifications](https://docs.bsky.app/docs/api/app-bsky-notification-list-notifications), [post records](https://docs.bsky.app/docs/advanced-guides/posts), [post-view lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/defs.json).

### Facebook Pages

- **Inbox.** Use Page-owned published posts, the post's comments edge, and comment replies where visible. Validate Page roles/tasks and the endpoint's requirements for `pages_read_engagement`, `pages_read_user_content`, and `pages_manage_engagement`. The Page `feed` webhook can deliver comment and reaction changes after app installation and subscription. Meta documents `pages_manage_metadata` and `pages_show_list` for that setup. A reachable, verified webhook endpoint is additional work.
- **Performance.** Page posts expose comments, reaction summaries and share information where returned. Query `/{page-post-id}/insights` with `read_insights` and the required Page access. Meta lists `post_media_view` and `post_total_media_view_unique`. Check the deployed API version and actual media type before offering views, clicks, or video breakdowns. Meta has retired legacy impression metrics. Page Insights also has eligibility, freshness and history constraints, including a documented minimum of 100 Page likes. Verify the behavior on small Pages.
- **Gap.** Add an explicit post-insights adapter. A Page post, photo and video may have different object IDs. Match the ID to the endpoint before joining comments or metrics. Scope this provider to Pages.

Sources: [Page feed](https://developers.facebook.com/docs/graph-api/reference/page/feed/), [Page post](https://developers.facebook.com/docs/graph-api/reference/page-post/), [reactions](https://developers.facebook.com/docs/graph-api/reference/page-post/reactions/), [insights permissions](https://developers.facebook.com/docs/insights/get-started), [metrics and deprecations](https://developers.facebook.com/docs/graph-api/reference/insights/), [Page webhooks](https://developers.facebook.com/docs/graph-api/webhooks/getting-started/webhooks-for-pages/).

### Threads

- **Inbox.** `/{thread-id}/replies` lists replies. `/{thread-id}/conversation` returns paginated top-level and nested replies in a flat list. Use returned parent/root IDs and `is_reply_owned_by_me` where available. Publishing a reply uses `reply_to_id`. Validate `threads_basic`, reply read/manage grants and publishing grants on the connected profile.
- **Performance.** `/{thread-id}/insights` with `threads_manage_insights` gives metrics for owned posts, including views, likes, replies, reposts, quotes and shares. Meta documents empty insights for repost facades and exclusions for nested reply metrics. Views are a provider-defined count.
- **Gap.** Add `/conversation` and insights support. Test whether replies sent directly in Threads are recognized before claiming reliable unanswered status.

Sources: [Threads API and permissions](https://www.postman.com/meta/threads/overview), [conversation](https://www.postman.com/meta/threads/request/34203612-13ebe336-0176-4d2b-b208-c36646093139), [respond to replies](https://www.postman.com/meta/threads/request/34203612-7abb4419-a216-4e06-8027-f9f4fcf8bee9), [Threads insights](https://developers.facebook.com/docs/threads/insights/).

### Instagram

- **Inbox.** Scope the current Facebook Login flow to Business and Creator accounts linked to an authorized Facebook Page. List owned media and read `/{ig-media-id}/comments`. Read or create nested replies via the comment's replies edge with the appropriate grants, including `instagram_manage_comments` for the current login flow. Meta also documents comments and mentions webhook events. Story and live media behavior needs separate validation.
- **Performance.** Media metadata can provide `like_count`, `comments_count`, and media classification. `/{ig-media-id}/insights` supports metrics such as views, reach, saves, and shares depending on media type. For Facebook Login, verify `instagram_basic`, `instagram_manage_insights`, and `pages_read_engagement`, plus any additional role-dependent permissions. The separate Instagram Login flow uses different scopes and host.
- **Gap.** Add nested reply reads and media insights. Verify version-specific metric support for feed posts, carousels, and reels independently. Treat missing metrics as unavailable.

Sources: [Meta's Instagram API reference collection](https://www.postman.com/meta/instagram/documentation/6yqw8pt/instagram-api), [media insights and permissions](https://developers.facebook.com/docs/instagram-platform/insights/), [Instagram webhooks](https://developers.facebook.com/docs/graph-api/webhooks/getting-started/webhooks-for-instagram/).

### X

- **Inbox.** The current adapter uses `/2/tweets/search/recent` with `conversation_id:<id> is:reply`. Recent search covers the last seven days of matching replies. An old root may still get a recent reply. Use `referenced_tweets` to identify a direct parent, and user-context write access for replies. Validate endpoint entitlement, actual billing, and rate limits before enabling automatic polling. Full-archive search is a separate route and is not integrated.
- **Performance.** Post `public_metrics` includes likes, replies, reposts, quotes and impressions. Inspect the returned fields before showing other metrics. Private clicks and organic/promoted metrics require author user context and are limited to posts from the last 30 days. Video metrics use media fields. The app currently maps only the public like count.
- **Gap.** Extend mapping first. Treat search coverage gaps as unknown reply status and use a bounded sync budget per connection.

Sources: [recent search](https://docs.x.com/x-api/posts/search-recent-posts), [conversation IDs](https://docs.x.com/x-api/fundamentals/conversation-id), [metrics](https://docs.x.com/x-api/fundamentals/metrics), [pricing](https://docs.x.com/x-api/getting-started/pricing).

### LinkedIn

- **Inbox.** `/rest/socialActions/{post-urn}/comments` and comment social actions support comment threads. Organization reads and writes use Community Management feed permissions such as `r_organization_social_feed` and `w_organization_social_feed`, approved product access and eligible Page roles. Member feed read access (`r_member_social_feed`) is restricted. Treat separately the restricted `r_member_social` used for member post reads. A member who can publish with `w_member_social` has no implied inbox access.
- **Performance.** Social actions or social metadata supply reaction and comment aggregates under applicable grants. Organization `organizationalEntityShareStatistics` provides organic impressions, unique impressions, clicks, comments, likes and shares with `rw_organization_admin` and a rolling 12-month window. Member `memberCreatorPostAnalytics` documents post-level impressions, reach, reactions, comments and reshares with `r_member_postAnalytics` and approved access.
- **Gap.** The current optional feed connection requests feed permissions. Its scope list does not include either reporting permission above. Validate the actual developer product, approved scopes, account role and Marketing version before enabling organization or member analytics.

Sources: [Community Management access and restrictions](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/community-management-overview), [social actions permissions](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/network-update-social-actions?view=li-lms-2026-10), [organization share statistics](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/organizations/share-statistics?view=li-lms-2026-10), [member post statistics](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/members/post-statistics?view=li-lms-2026-10).

### Mastodon

- **Inbox.** Use the connected account's instance. `GET /api/v1/statuses/:id/context` supplies ancestors and descendants the instance knows about. `GET /api/v1/notifications` can supply incoming mentions, including replies, with notification read permission. Use `POST /api/v1/statuses` with `in_reply_to_id` and status write permission. An instance's federation and visibility limits can leave threads incomplete.
- **Performance.** Status supplies favourites, boosts and reply counts. Quote count depends on server version (introduced in 4.5). Standard Status provides no views, impressions, reach, or link clicks.
- **Gap.** Add SDK context, notifications and reply support and verify requested scopes. Keep instance-local IDs scoped to the instance and validate discovery for the connected server version.

Sources: [statuses](https://docs.joinmastodon.org/methods/statuses/), [Status fields](https://docs.joinmastodon.org/entities/Status/), [notifications](https://docs.joinmastodon.org/methods/notifications/), [federated reply visibility](https://docs.joinmastodon.org/user/network/).

## Rules for proposals and implementation

1. For each provider and account type, cite the endpoint and fields, verify the package pin and app facade, then record required grants, app approval, roles, media types, API version, pagination, lookback, cost, and provider storage restrictions. Treat unknowns as research tasks. Label doc-only findings separately from live-verified capabilities.
2. Before shipping a capability, test signed-app access with an eligible account. For Inbox, cover a fresh comment, a nested reply, a direct-on-provider reply, paging and missing grants. For metrics, cover returned zero, omitted fields, expired grants, unavailable media types and older posts.
3. Key posts by provider, server, authorized identity and provider post ID. Support native posts when an account listing can discover them. Link manual or recovered publications only after verifying the remote ID; some delivery receipts lack it.
4. Keep Needs Reply, Replied, and Done as app workflow states. Identify a connected account's reply through verified author or ownership data and parent links. Preserve uncertainty on incomplete threads. Read/unread provider notifications track a different state.
5. Start automatic sync with bounded recent reads while the app runs, per-account cursors or overlapping refresh windows, deduplication, per-account last-success timestamps, and provider-aware backoff. Specify a backend or provider event subscription separately if proposing closed-app updates. A webhook does not provide historical backfill.
6. Store supported metrics as timestamped observations with provider definitions and a distinction between zero, unavailable, stale, and not yet fetched. Compare post type within a profile at comparable ages and report sample size. First-seven-day results require snapshots collected during that window or a verified historical endpoint. Never combine views, impressions and unique reach under one metric or derive a click count from public likes.
7. Recheck this reference when a provider adds or retires an endpoint, when app grants change, and when bumping SocialKit. Record the tested API version and date for each capability verified live.

## Initial research priorities

- Pilot Threads and Instagram on accounts with existing reply access. Validate nested replies and the reporting grant before committing to Needs Reply accuracy or views. Facebook Pages is another existing reply path with separate insights eligibility.
- Prototype Bluesky and Mastodon as engagement-count providers once SDK reply and notification coverage is added. Validate X polling cost and LinkedIn approval separately.
- Keep mentions, direct messages, ad reporting, recipient lists for likes, and comment reactions out of the initial feature promise unless the specific provider operation is documented and tested. A count, an event feed, and permission to react are distinct capabilities.

# Indie Dev Buddy — Product & Implementation Specification

**Status:** MVP specification • **Target:** macOS, SwiftUI • **App name:** Indie Dev Buddy  
**Audience:** Solo/independent Apple-platform app developers who build, release, and market their own apps.  
**Primary goal:** Make it easy to find, connect, edit, and reuse everything *outside the code editor* involved in running and promoting an indie app, without a backend, account setup, or custom agent integration.

> **Product promise:** Your apps, websites, social accounts, files, and marketing content in one understandable, local-first workspace.

**Deferred feature:** App release/version tracking is currently disabled in the interface. The app does not show version lists, latest versions, release views, or content-to-release links. Existing release files and legacy `releaseId` fields remain untouched for compatibility.

### Existing Xcode project and code locations

Implement this specification in the existing Xcode project; do not create a second project unless the existing one is missing or unusable. Paths below are relative to the repository root:

- Xcode project: `Indie Dev Buddy.xcodeproj`
- App source directory: `Indie Dev Buddy/`
- App entry point: `Indie Dev Buddy/Indie_Dev_BuddyApp.swift`
- Main view: `Indie Dev Buddy/ContentView.swift`
- Unit tests: `Indie Dev BuddyTests/`
- UI tests: `Indie Dev BuddyUITests/`
- Build products and indexes under `DerivedData/` are generated artifacts, not source files.

Keep product naming consistent with **Indie Dev Buddy** in user-facing app surfaces and documentation. The selected user data workspace is separate from this source repository and Xcode project.

## 1. Product boundaries and principles

The product is **an app-development and marketing workspace**, **not** a general notes app, social analytics platform, project manager, CRM, or code editor. It supports per-account API scheduling where SocialKit and provider access are configured, alongside the existing manual posting workflow. Marketing workflows have priority over developer-project management.

1. **Recognizable, explicit navigation.** Use plain labels such as **Apps**, **Marketing Content**, **Websites & Social Accounts**, and **Files**. Avoid unexplained labels such as “Profiles,” “Spaces,” “Nodes,” and “Destinations” in the UI. Every important section and action should be discoverable without hunting in contextual menus.
2. **One fact, one record.** Store every app, identity, website, and social account once. Show it in multiple relevant views through references; do not create duplicate copies for each app or post.
3. **Apps are the center.** App pages collect website pages, App Store details, source-project locations, assets, and associated marketing. Global sections let users work across all apps.
4. **One source, optional branches.** A blog article or post can generate related content. A social post can use the same original text for several accounts and selectively customize individual account versions. Changes to one custom version never overwrite the original or other versions.
5. **Files are the source of truth.** Every user-authored content record lives in a user-selected, human-readable filesystem workspace. The UI reads/writes those files; an external AI coding agent can do the same using ordinary filesystem access. Social credentials stay in the device-local Keychain, never in workspace records. Meta app secrets stay in a trusted OAuth exchange service; no marketing content backend is introduced.
6. **Manual or API-assisted publishing.** Each social destination can be scheduled for API delivery when a supported SocialKit connection is available, or marked **Manually Scheduled** for the existing copy/open/post workflow. A manual schedule never sends anything. Make the selected delivery mode, scheduled time, and resulting state explicit; do not imply API delivery when it is unavailable.
7. **Warn, do not block.** Character-length guidance and publish-readiness hints must not prevent editing, saving, or copying. They are informational, approximate, and editable as platform policies change.
8. **Function before flourish.** Use native SwiftUI/AppKit components and a small codebase. All visible actions must work. Prefer a reliable, complete simple workflow over beautiful but inert controls or elaborate infrastructure.

### Out of scope for v1

Incoming social-mentions inboxes and social analytics, automatic website publishing, App Store Connect APIs, Git operations, build/test automation, parsing Xcode projects, AI generation/summarization, custom workflows or schemas, graph canvas, kanban boards, collaboration/multi-user, sync server, rich-text/HTML website builder, subscriptions, advanced image editing, bulk migration from all third-party apps, and mobile counterparts. Outbound Bluesky mentions are supported when resolved to a DID and saved in the API schedule payload; other mention formats remain plain text. Social API publishing and account interactions are limited to providers, media types, permissions, and accounts supported by the configured SocialKit integration.

## 2. Terminology and relationships

Use a small fixed model. Technical names may differ internally, but user-facing wording must be clear.

| Record | Purpose | Key relationships |
|---|---|---|
| **Identity** | A person or business/brand, e.g. “Shawn” or “Brave New Design.” | Owns apps, websites, social accounts. |
| **App** | An Apple app, e.g. Dictate Bar or Pueblo CRM. | Has a primary developer identity; may itself own social accounts or a dedicated website; connects to website links, content, assets. |
| **Website** | A domain/site, recorded **once**, e.g. `bravenewdesign.com` or `pueblocrm.com`. | Has an owner (identity or app). Can be linked to many apps and optionally be a blog publishing destination. |
| **App Website Link** | A particular page on a website serving an app. | References app, website, URL and purpose (product, support, privacy, docs, etc.). One may be marked primary app URL. |
| **Social Account** | A configured account on one platform, e.g. Brave New Design's Threads account. | Platform, editable display name/handle/profile URL, optional workspace avatar, owner (identity or app), enabled flag, and optional verified provider identity for API delivery. Posts reference its local record ID; the provider identity is separate from editable profile metadata and contains no credentials. |
| **Marketing Content** | Blog article, social post, or general marketing draft. | App (optional), website/blog destination or social destinations, status, attachments, source/related content, published URL(s). |
| **Post Version** | A customized version of a social post for **one social account**. | Belongs to a marketing content record and account; otherwise account uses shared original text/assets. |
| **Asset** | Image, video, PDF, or other file. | Stored alongside an app/content item or in shared files, referenced by relative path. |

An app should **not** require a separately duplicated brand record merely to own an app-specific social account. Use an owner reference that can point to an identity or an app. Avoid cycles in the app's primary-developer relationship.

### Critical website use case

**Brave New Design** owns `bravenewdesign.com` once. Several smaller apps may have their primary product/support/privacy pages under `bravenewdesign.com/software/...`. **Pueblo CRM** can additionally use its own dedicated `pueblocrm.com` while retaining links to its pages on Brave New Design. A blog article about Pueblo may be published on either applicable site. The site owner and the app being discussed are **not always the same**.

For each app, support multiple labeled website links across shared and dedicated sites. Distinguish **primary app page** from **website owner** and **blog publishing destination**.

## 3. Information architecture and screens

**Main sidebar, always visible when window size permits:**

1. **Apps** — expandable list of apps. Selecting Apps opens an overview/grid or clear list; selecting an app opens its details.
2. **Marketing Content** — All Content, Blog Articles, Social Posts, Drafts, Ready, Published, **Ideas/Inbox**, and optional group-by-app view. These are filters on the *same* records, not duplicate folders.
3. **Websites & Social Accounts** — identities/owners, websites, and enabled/disabled social accounts in one understandable place. Show the owner next to each account across all lists.
4. **Files** — file browser for the workspace and shared marketing assets, with Reveal in Finder and ordinary file/folder operations.

Top bar: discoverable **Search** and **+ Create** (App, Blog Article, Social Post, Idea, Website, Social Account). Specific views also show a clearly labeled primary Add/Create action. Use sensible empty states with direct creation actions.

### Apps overview

Use a native macOS split view for the workspace sidebar. The Apps list and selected
app detail use the same main pane, so selecting an app leaves the full pane available
to the editor. The toolbar’s **All Apps** action returns to the list and follows the
same unsaved-change rules as other navigation. The app header and native segmented
control stay visible above the active tab. Websites & Social Accounts can retain
a separate record list beside its editor for browsing and comparison.

A compact, scannable list/grid showing icon, name, platforms, and summary of related marketing work. No fabricated analytics or activity numbers. New app action prominent.

### App details

Stable header with app icon, name, developer identity, and platforms. Use **Overview / Marketing / Files** as explicit tabs or segmented navigation.

- **Overview:** description, bundle ID(s) (optional), Xcode project location, repository URL, App Store/TestFlight URLs, primary app URL and other website links (support/privacy/docs), and recently related items. Open/reveal links in the correct external app.
- **Marketing:** all blog/social content associated with the app, grouped related items where useful; New Marketing Post and New Blog Article actions.
- **Files:** app assets and linked external project/changelog locations. **Never copy an entire Xcode project into this workspace by default.** Let the user choose a project directory or `.xcodeproj`/`.xcworkspace`; store a reference with a visible human-readable path and a security-scoped bookmark for reopening.

### Websites & Social Accounts

Show a list/table with platform/site, visible name, handle or URL, **Owner**, enabled state, and Add/Edit. Owners are identities (personal/business) and apps; filter by owner. Selecting an owner shows its websites and accounts without duplicating their data. Selecting an app elsewhere should also surface relevant accounts and website pages without sending the user on a scavenger hunt.

A **social account** is eligible in a new social post **only if** it is enabled, has an owner, and has an identified platform plus at least a handle or a profile URL. Disabled or unconfigured accounts are excluded from selection, even if older drafts still reference them. Existing drafts retain their references and display an unavailable/disabled warning rather than silently deleting content.

A **website** is a blog destination only when the user has enabled/configured blog publishing for that website. Store base URL and optional blog index URL. Never infer a blog from a domain alone.

### Marketing Content list and related-content detail

Show type, title, app, destination/owner, and status. Grouping by a blog original or content family is available, but the user can always see individual content records. A related-content detail shows **Original / Created From**, **Other Related Content**, each account variant and publication state. Clicking any item navigates to its editor. Relationships should remain visible when a related item is opened.

### Composer layout (most important screen)

Clearly divide: (a) title + metadata; (b) original editable body; (c) eligible destination accounts; (d) selected account's preview and any customization. On a large window, place previews alongside the editor. On a smaller window, use a clearly labeled Preview toggle/tab instead of hidden inspectors.

- **Blog article:** title, destination website, Markdown body, optional excerpt, featured image/files, app(s) mentioned, status and published URL; **Create Related Social Post** is prominent. Blog text remains its own original article; do not replace it with the social summary.
- **Social post:** internal title, app association, optional source blog/post, **shared original text**, images/files, selected social accounts, optional customized text/media for each account, per-account preview, character guidance, copy controls, and per-account status + published URL.
- A new social post may start with one shared message for all chosen accounts. Choosing **Customize for this account** creates a branch **initially copied** from the shared text; editing the branch does not change the original. **Use original instead** asks for confirmation if customized edits will be discarded.
- Original edits update accounts still using the original. They **never overwrite** customized versions. Custom versions display “Based on original” and offer **View Original / Copy from Original**.
- Account rows always identify **platform + username + owner**, e.g. `Threads · @example · Brave New Design`. Avoid an unlabeled icon-only channel row.
- An account may have a different publication status and URL from the other accounts in the same social post. A global Published label applies only when all selected destinations are marked published; otherwise show Mixed/Partially Published or each status clearly.
- Default selected images can be shared across accounts. For an account version, allow replacing/choosing its attachments without affecting others. Keep asset handling plain; no built-in crop/edit suite.

### Previews and character guidance

Provide recognizable **SwiftUI-rendered platform-inspired preview cards**, not browser sessions or fully cloned social websites. Begin with Threads, Instagram, X, Facebook, LinkedIn. Additional platforms can be added later. Show account name/handle, avatar (when available), post text, media thumbnails, and appropriate platform-style hierarchy. Do **not** render nonfunctional like/comment/share controls as if they were clickable.

- The preview reflects the **actual selected account's effective text**, media, and appended article link, not a generic sample.
- Show `current / guideline` for each selected account, and an obvious warning when over the configured limit, e.g. **“Over this platform's suggested limit — review before posting.”** Save and Copy remain enabled.
- Provide configurable per-platform text-length guidance in local settings/config; policies vary, especially with media, URLs, account types, Unicode, and subscription tiers. Do not pretend a simple character count is identical to platform validation. Count consistently and label it as guidance.
- For blogs, text length is not constrained as social content. Where a platform may require media (such as Instagram), show a readiness hint, not a blocking error.
- Show only selected accounts in the composer. Do not display every possible platform by default.

### Publishing status and copy workflow

Statuses: **Idea / Draft / Ready / Scheduled / Manually Scheduled / Published**. API-scheduled delivery stores an immutable per-destination snapshot of the approved text, resolved mentions, recipient identity, media, and due time, then sends that payload through SocialKit. Editing the ordinary draft does not change an already approved send; the user must choose **Reschedule with Current Draft** to replace its payload. Manual scheduling stores a date only; the user still copies, opens the destination, posts, and marks it Published. Marking a destination as Published optionally captures its final public URL and publication date. The global content list derives status from destination states, including mixed manual/API schedules.

The social account scope is Bluesky, Facebook Pages, Threads, Instagram, X, LinkedIn, and Mastodon. Custom platforms and personal Facebook profiles use manual posting. The app offers local scheduling when the connected account, provider capabilities, and media format permit it. See [Social connections and local delivery](SOCIAL_CONNECTIONS.md) for provider setup and media formats. Confidential connections require registered callbacks, a trusted HTTPS exchange service, provider permissions, and signed app configuration. Store provider credentials in the device Keychain and keep provider app secrets on the exchange service. Workspace files carry only the verified remote identity and scheduled payload.

Initial scheduled delivery runs locally: Indie Dev Buddy must remain open and the Mac awake at the due time. If either condition is not met, surface the item as overdue for review on the next launch; never silently publish it late. Persist a per-destination schedule snapshot and delivery history with timestamps, outcome, provider post ID/URL when available, safe error details, and retry/reconciliation state. Do not automatically retry an uncertain publish; require checking the provider first to prevent duplicates. Manual scheduling creates no delivery attempt. Offline delivery is a later milestone using an external scheduling service, linked to Indie Dev Buddy. That service will need an explicit design for schedule synchronization, credential custody, media hosting, and delivery reconciliation; it is not part of the local scheduler.

Provide an account activity view for SocialKit operations exposed by the connected account's current capabilities, such as reading posts/replies, replying to a post, liking/unliking, hiding or deleting replies where supported. Hide unavailable actions and explain missing permissions. Activity actions are user initiated; do not imply support across every network. Preserve an operation history without storing access tokens or raw provider response bodies.

Offer clear actions: **Copy Text**, **Copy Image** or **Copy/Drag Media**, **Open Social Account**, **Open Website**, **Schedule via API**, **Mark as Manually Scheduled**, **Mark as Published**, and **Reveal Assets Folder**. Copy the *currently selected variant* and resolved source link, not always the original. Keep the manual workflow fast for every account, including providers without an available API connection.

## 4. Content branching and linking rules

**Example A — identical holiday message:** Create one social post, select business, personal, and app-specific social accounts. All initially use the shared original. Copy each account's effective text without creating four duplicate drafts.

**Example B — app update:** Create one “Dictate Bar update” social post. Business Threads uses a polished business version, personal Threads uses a conversational first-person version, LinkedIn uses the original, Instagram uses a shorter customized version and its own images. All remain in one post record.

**Example C — long article to social:** Write a blog article for Brave New Design, associated with Dictate Bar. Choose **Create Related Social Post**. The social item links to the article and can start with user-selected excerpt/text (or an empty draft). It need not copy the entire long article, and no AI summarization is implied. The user edits a social-specific message and selects accounts. The blog article can have its own publication status/URL; derived social posts and their per-account variants retain a visible **Created from [article]** relationship.

To link to a published article without overwriting variants, offer **Include Link to Original Article** for social posts. When enabled, compose/preview/copy output includes the source article's stored published URL. If the article isn't published or lacks a URL, show **“Article link unavailable until a published URL is added”** and let the user continue editing/saving; do not fabricate a URL. The original social body stays unchanged by this link operation. The preview's length guidance must reflect the effective copied text including a resolved URL.

Use **one-way `sourceContentId` / `relatedGroupId` references** and derive reverse links; don't require users or agents to maintain duplicate two-way relationship arrays. All IDs must remain stable across renames and moves. Show a friendly warning for missing references, never crash.

## 5. Local-first storage contract

The user chooses **one workspace folder** at setup. Their ordinary files (Markdown/text/JSON/media) live inside it. Do not bury records in private app storage or make an opaque database the only source of truth. The app can use transient in-memory indexes and local preferences for navigation state.

Suggested on-disk layout (exact filenames may be refined once, before implementation):

```text
Indie Dev Buddy Workspace/
├── workspace.json                 # schema version and workspace ID
├── AGENTS.md                      # how external agents safely edit records
├── Identities/
│   └── brave-new-design/record.json
├── Apps/
│   └── dictate-bar/
│       ├── record.json
│       ├── Releases/1.3/record.json  # legacy release data; not currently surfaced
│       └── Assets/
├── Websites/
│   └── bravenewdesign/record.json
├── SocialAccounts/
│   └── threads-business/record.json
├── Content/
│   ├── dictate-bar-todos-blog/
│   │   ├── record.json           # blog, websiteId, sourceContentId, publishedURL
│   │   ├── body.md
│   │   └── Assets/
│   └── dictate-bar-todos-social/
│       ├── record.json           # social, sourceContentId = blog ID
│       ├── original.txt
│       ├── Variants/
│       │   └── threads-personal.txt
│       └── Assets/
├── Inbox/
└── Shared Files/
```

**Data contracts:** JSON uses `schemaVersion`, stable opaque `id`s, simple typed fields, references by ID, relative paths for workspace assets, and ISO-8601 dates when needed. Store app/site/account names only in their own records; elsewhere refer to IDs. `AGENTS.md` documents mandatory fields, example JSON, how to create/edit items, references, no secret tokens, and atomic writes. The app must validate JSON and show actionable file-specific errors rather than dropping malformed items.

### Minimal example record contracts (illustrative, not an additional database)

Keep the first implementation compatible with these shapes or document one equivalent, consistently used schema. Names and URLs below are illustrative—not automatically verified or fetched.

**Website** (`Websites/brave-new-design/record.json`):

```json
{
  "schemaVersion": 1,
  "id": "website-bnd",
  "name": "Brave New Design",
  "owner": { "type": "identity", "id": "identity-bnd" },
  "baseURL": "https://www.bravenewdesign.com",
  "blogEnabled": true,
  "blogIndexURL": null
}
```

**App** (`Apps/dictate-bar/record.json`):

```json
{
  "schemaVersion": 1,
  "id": "app-dictate-bar",
  "name": "Dictate Bar",
  "developerIdentityId": "identity-bnd",
  "platforms": ["macOS"],
  "projectPath": null,
  "websiteLinks": [
    { "id": "app-link-product", "websiteId": "website-bnd", "purpose": "product", "url": null, "isPrimary": true },
    { "id": "app-link-support", "websiteId": "website-bnd", "purpose": "support", "url": null, "isPrimary": false }
  ]
}
```

**Social account** (`SocialAccounts/threads-personal/record.json`):

```json
{
  "schemaVersion": 1,
  "id": "account-threads-personal",
  "platform": "threads",
  "owner": { "type": "identity", "id": "identity-personal" },
  "handle": "@example",
  "profileURL": null,
  "enabled": true
}
```

**Related social content** (`Content/dictate-bar-todos-social/record.json`):

```json
{
  "schemaVersion": 1,
  "id": "content-todos-social",
  "kind": "social",
  "title": "Dictate Bar To-do Announcement",
  "appIds": ["app-dictate-bar"],
  "sourceContentId": "content-todos-blog",
  "originalBodyPath": "original.txt",
  "includeSourceLink": true,
  "destinations": [
    { "accountId": "account-threads-business", "bodyPath": null, "status": "draft", "publishedURL": null },
    { "accountId": "account-threads-personal", "bodyPath": "Variants/threads-personal.txt", "status": "draft", "publishedURL": null }
  ]
}
```

For these examples, a null `bodyPath` means **use `original.txt` live**, not a copied snapshot. Use separate files only when customized. The schema must also support relative media paths and optional per-account media overrides.

**External locations:** The user's Xcode project, repo, and changelog may be **outside** the workspace. Store readable paths and/or URLs in records. For sandboxed access across restarts, store the necessary security-scoped bookmark grants in device-local application settings keyed by stable record/reference IDs; prompts for permission should be clear. Do not force an Xcode project into the marketing workspace or automatically modify project files. When access is lost, show **Relink Folder/File**. Project paths must be browsable/openable, not parsed for v1.

**Updates from AI agents and other apps:** Watch the chosen workspace recursively using an appropriate macOS file-event mechanism; debounce/coalesce updates; reload affected records and thumbnails. An agent can add a valid item or modify Markdown/JSON and the app should reflect it without a restart. Avoid overwriting unsaved local edits: save atomically and handle external modification conflicts explicitly with Reload vs Keep Local (or an equivalent simple recovery). Have a manual Refresh action as a fallback. Do not watch huge Xcode trees recursively in v1; linked external files can refresh when reopened or on demand.

**Portability:** Workspace content should survive app deletion and be understandable without the app. Grant/permission state may need to be reauthorized on a different Mac. No user credentials or API secrets belong in these records.

## 6. Native macOS implementation guidance

- Swift 6+ and SwiftUI; `NavigationSplitView`, standard `List`, `Form`, `TextEditor`, `TextField`, `Picker`, file panels, drag/drop. Use lightweight AppKit interop where it materially improves pasteboard, opening files, or filesystem observation.
- Foundation `Codable` for JSON, `FileManager` for storage, `NSPasteboard` for images/text, `NSWorkspace` for opening or revealing external items, security-scoped bookmarks for external files/folders, and a directory-watching service for workspace changes.
- No Core Data/SwiftData requirement, no server, and no third-party UI libraries by default. Avoid elaborate abstraction layers; keep file service, record index, editor state, and simple views separate for testability.
- Text editing is **plain text for social drafts** and **Markdown for blog articles and notes**. No WYSIWYG HTML editor. Asset paste and drop must save a usable file directly into the appropriate `Assets/` directory. Offer **Reveal Assets Folder** so Photoshop or another design tool can export there directly.
- Support standard keyboard navigation, reasonable window resizing, meaningful empty states, labels/tooltips, keyboard shortcuts for search/new content/copy, VoiceOver/accessibility labels, and system light/dark appearance. No icon-only mystery navigation.
- Use modest, native styling inspired by the latest mockup: calm sidebar, clear titles, useful whitespace, restrained accents. The image is **conceptual reference**, not a pixel-perfect spec. Do not implement decorative mock data as functional data.

## 7. First-run and core flows

### Setup
1. First launch shows **Choose a Workspace Folder** or **Create New Workspace** (one decision; don't require external accounts).
2. Explain plainly: “Your information is saved as ordinary files in this folder. You can edit it with other apps and AI tools.”
3. Offer **Add Your First App** (name required; other fields optional). No forced identities/websites/accounts on first run.

### Add app and website
1. Create app (name, optional icon/owner/platform).
2. From Overview, select Xcode project location and add App Store/support/privacy/product links.
3. To associate a shared site, select an existing website or create it once; add each app-specific URL with role and primary marker.
4. Verify another app can reference the **same** website without duplicating its record.

### Configure social accounts
1. In Websites & Social Accounts, add owner (person/business or existing app), platform, handle and/or profile URL, optional avatar, and Enabled toggle.
2. Account appears in the global list with owner shown and in eligible compose options when enabled and sufficiently configured.
3. Disable it; it disappears from **new selectable destinations** while existing posts remain intact.

### Create and branch marketing content
1. Write original blog article, choose an enabled blog website and app; save as Draft.
2. Choose Create Related Social Post, seed from selected text if desired, and select available accounts.
3. Keep common original post text; customize only personal Threads and Instagram; keep business account using original.
4. Inspect accurate per-account platform-styled previews, effective character-length guidance, media, owner, and status.
5. Mark blog article Published with its real URL; the related social post can now include the link on preview/copy.
6. Copy each effective post and media; manually publish externally; mark each destination Published and enter its URL. View the complete related-content family from any item.

### External agent editing
1. Agent reads the generated `AGENTS.md`, adds/edits valid JSON/Markdown/text/media in the workspace.
2. App refreshes the changed items; edited branch/metadata can be found from relevant app and marketing views.
3. Invalid JSON is surfaced safely; conflicts do not silently destroy local edits.

## 8. Acceptance criteria / release gates

The MVP is **not** complete just because the UI compiles. Agent must verify all of the following with automated tests where practical and an actual running macOS interaction check:

- [ ] Create/open workspace in a normal selected folder; restart and reopen with persistent access; records are real files.
- [ ] Add/edit/reopen an app; open/reveal a linked Xcode folder, `.xcodeproj`, and external changelog; unavailable locations show Relink rather than crashing.
- [ ] Store Brave New Design website **once** and attach multiple distinct product/support/privacy pages to different apps; Pueblo can also have its own site and BND pages.
- [ ] Add social accounts for personal, business, and an app; owner, handle, platform, enabled state visible globally and in destination picker.
- [ ] Disabled/missing-identity social accounts cannot be newly selected; previously authored posts remain intact and show explanation.
- [ ] Draft a long Markdown blog article and relate a social post to it; open the social post and navigate to the source article and related items.
- [ ] Select several accounts; all start with original text. Customize one account, edit original, verify only uncustomized destinations change; reselecting restores correct branch.
- [ ] Per-account media can inherit or override shared media; paste and drag image directly into a post and verify an actual asset is saved on disk; Reveal Assets Folder works.
- [ ] Each selected platform preview shows correct account/owner/effective text/media, character count, and over-limit warning. Over-limit content still saves and copies.
- [ ] With source-blog linking enabled, missing published URL shows nonblocking warning; when URL supplied, preview and Copy Text include the correct link without rewriting original text.
- [ ] Copy Text uses the selected account's text and resolved link; Copy Image/drag media works. Mark Published stores URL/date **for the correct account** and does not perform external publishing.
- [ ] Rename an app/content title or folder and preserve relationships via stable IDs; broken IDs show warning rather than crash.
- [ ] Agent-like external changes to Markdown/JSON/images update UI without restart; local unsaved changes are not silently overwritten; malformed files generate visible actionable errors.
- [ ] Empty states, Add buttons, search, tabs, keyboard access, and navigation all work; no nonfunctional visible buttons or falsely active integrations.

## 9. Implementation sequence and stop rules

**Milestone 1 — File-backed foundation:** workspace picker/permissions, schemas/index, app create/edit/list, identity/site/app links, Files/Open/Reveal, reliable persistence. Produce a working build and tests.

**Milestone 2 — Social identities + publishing editor:** owner-aware accounts/enablement, marketing content list, blog Markdown editor, social shared original and per-account branches, status, attachments/paste/drop, copy. Produce a working end-to-end demo.

**Milestone 3 — Relationships + previews + external edits:** article-to-social derivation, blog link resolution, per-platform preview cards/guidance, external file observation and conflict recovery, polish and acceptance tests.

Prefer a smaller **working** vertical slice at every milestone. If a feature requires disproportionate custom code, implement the simplest user-facing behavior specified here and note a bounded follow-up instead of introducing a framework, API integration, or generalized schema engine. Do not quietly replace requirements with placeholders. Report incomplete acceptance checks explicitly.

## 10. Decisions, priorities, and guardrails for the coding agent

- Make the spec and acceptance criteria the implementation authority; the visual mockup is a layout reference, not a full contract (its “Publish”/“Scheduled” affordances must be interpreted as manual **Mark Published** / **Planned**).
- Use sensible defaults without repeatedly asking cosmetic questions. Ask only when ambiguity risks destructive data changes or fundamentally different workflows.
- Do not build alternate duplicate stores (e.g. SwiftData **plus** JSON as competing sources of truth).
- Avoid premature abstractions: content variants and link references can be simple IDs/paths, not a generalized graph framework.
- Do not automate web posting, claim to verify real-world character eligibility, or invent App Store/platform data.
- Write/maintain `AGENTS.md` and sample workspace fixtures for external AI agents, with no credentials.
- Keep all record types understandable and modifyable by both users in the UI and agents on disk; import/export is just ordinary file access.
- No fake buttons, placeholder flows, overly dense dashboard, hidden critical commands, or duplicated metadata entry.
- Development decisions and test failures should be summarized in an implementation report. If making a tradeoff against this spec, state it and why.

**Definition of success:** A solo Apple developer can open the app, find their project and app links, prepare a blog article and related channel-specific social versions, attach and copy images, visually review what each account will see, mark publications with URLs, and let an external AI agent update all that content by editing ordinary files—without confusion or an account setup flow.

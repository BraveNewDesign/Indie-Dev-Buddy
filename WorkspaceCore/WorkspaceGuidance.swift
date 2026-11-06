import Foundation

/// Reference material for schema version 1. Existing workspace files always belong to the user.
nonisolated enum WorkspaceGuidance {
    static let version = 1
    static let files: [(path: String, contents: String)] = [
        ("AGENTS.md", agents),
        ("docs/DATA_FORMAT.md", dataFormat),
        ("docs/EXAMPLES.md", examples),
        (".agents/skills/indie-dev-buddy-content/SKILL.md", skill)
    ]

    // Exact shipped originals, so customized workspace instructions remain intact.
    static let priorCLIRevisions = [
        "AGENTS.md": "ffda75d6f1519dd2158963035965f4f3a7bf537b2edb8de33b0e9d6e6a85dfe7",
        ".agents/skills/indie-dev-buddy-content/SKILL.md": "e14564334144f84a1ed8a72c23eb511faedc522e3b67b6063032487f4ba7fccd"
    ]

    private static let agents = #"""
    # Indie Dev Buddy workspace

    Guidance version 2. Workspace schema 1.

    - Prefer the validated `indiedevbuddy` CLI for discovery, reads, and edits. Use `indiedevbuddy --help` for commands and install it from the Indie Dev Buddy app menu if needed.
    - Run `indiedevbuddy workspaces` to find the workspace path. Use that path with `--workspace` for `list`, `read`, `create`, `update`, and `validate`.
    - Select records by ID. Read a draft before updating it and pass the returned revision with `--revision`. Pass its body revision with `--body-revision` for body edits. If a write conflicts, read again and reconcile the changes before retrying.
    - Follow `.agents/skills/indie-dev-buddy-content/SKILL.md` for marketing tasks. See `docs/DATA_FORMAT.md` and `docs/EXAMPLES.md` for reference. Use the app for changes beyond the CLI's supported edits.
    - Preserve user content, unknown fields, stable IDs, media, and customized instructions. Keep workspace paths inside the workspace, and keep secrets out of it.
    """#

    private static let dataFormat = #"""
    <!-- Indie Dev Buddy guidance version: 1 -->
    # Workspace data format

    Guidance version: 1. The supported workspace manifest schema is `1`; records documented here use schema `1`. Check `workspace.json` first. Do not change a newer or unrecognized schema, unknown fields, or malformed records. Each record has a stable unique string `id`; generate a new UUID for each new record and retain existing IDs. JSON uses UTF-8; dates are ISO-8601 strings such as `2026-11-06T15:00:00Z`, URLs are strings, and optional fields may be omitted or null. Required fields below must be present even when arrays are empty. Paths are case-sensitive in these examples. Folder names are not record IDs.

    ```text
    workspace.json
    Identities/<folder>/record.json
    Apps/<folder>/record.json
    Apps/<folder>/Releases/<folder>/record.json
    Websites/<folder>/record.json
    SocialAccounts/<folder>/record.json
    Content/<folder>/record.json
    Inbox/
    Shared Files/
    ```

    `workspace.json` requires `schemaVersion` (integer), `id` and `name` (strings). The application scans one folder level under each record category. Releases belong within their app's `Releases` folder. Read the IDs from records rather than inferring them from paths. Each record below additionally requires `schemaVersion` and `id`.

    - **Identity:** required `name` (string); optional `kind` (string), `photoPath` (workspace-relative image path).
    - **App:** required `name` (string), `platforms` (string array), `websiteLinks` (array). Optional `description`, `iconPath`, `developerIdentityId`, `projectPath` (strings), `bundleIDs` (string array), `developmentStatus` (`development`, `beta`, `released`, `maintenance`, `archived`), and `repositoryURL`, `appStoreURL`, `testFlightURL` (URLs). `developerIdentityId` references an identity. Each website link requires `websiteId` and `purpose` (strings); `id` (stable link ID), `url` (URL), and `isPrimary` (boolean) should also be supplied. `websiteId` references a website. `iconPath` is relative to the app folder; `projectPath` may point outside the workspace.
    - **Website:** required `name`, `owner`, `baseURL`, `blogEnabled` (boolean); optional `blogIndexURL`. `owner` is `{ "type": "identity" | "app", "id": "..." }` and references that record.
    - **Social account:** required `platform` (string), `enabled` (boolean); optional `owner` (same shape), `handle`, `profileURL`, `avatarPath`. An eligible destination is enabled, has a nonempty platform, a resolving owner, and a nonempty handle or profile URL. `avatarPath` is relative to the workspace root.
    - **Release:** required `appId`, `version`, `status` (`planned` or `released`), `notesPath`; optional `releaseDate`, `assetPaths` (array), `externalChangelogPath`. `appId` must match the containing app's ID. Notes and assets are relative to the release folder. `externalChangelogPath` is a readable filesystem path and is a reference, not a copied file.
    - **Content:** required `kind` (`blog`, `social`, `idea`), `title`, `appIds` (array), `includeSourceLink` (boolean), `status` (`idea`, `draft`, `ready`, `published`), `destinations` (array), `mediaPaths` (array). Optional `websiteId`, `sourceContentId`, `releaseId`, `relatedGroupId`, `originalBodyPath`, `excerpt`, `plannedDate`, `publishedURL`. App IDs, website ID, release ID, and source content ID refer to existing records. A `sourceContentId` points from the related record to its source; reverse relationships are derived. Records sharing a `relatedGroupId` also appear together. `relatedGroupId` is a grouping string, not a record path.
    - **Destination:** each element of `destinations` requires `accountId` and `status`; optional `bodyPath`, `publishedURL`, `publishedDate`, `mediaPaths`. `accountId` references a social account. Use each account at most once per content record. A null or missing `bodyPath` uses the original body live; a path identifies a separate customized body. A null or missing destination `mediaPaths` inherits the content's media; an array overrides it, including an empty array for no media.

    `originalBodyPath`, destination `bodyPath`, and content or destination `mediaPaths` are relative to that content record's folder. Bodies are ordinary UTF-8 Markdown or text, not JSON front matter. Media are files at the referenced paths, often in `Assets/`; variants can live in `Variants/`. Keep all workspace-relative paths inside the workspace, including after resolving symlinks. Do not delete or replace a referenced original when adapting content. An optional asset path may point to a file; do not invent a reference without supplying the file.

    The app watches for external changes and detects conflicts when saving a loaded editor. Re-read before replacement; do not assume a multi-file update is atomic. See `EXAMPLES.md` for connected records and a draft.
    """#

    private static let examples = #"""
    # Connected examples

    Guidance version: 1. Each JSON block is a separate file at the indicated path. These examples use illustrative stable IDs; generate fresh IDs for new records. All referenced records and text files are included below.

    `Identities/studio/record.json`
    ```json
    {"schemaVersion":1,"id":"identity-studio","name":"Northstar Studio","kind":"business"}
    ```

    `Apps/beacon/record.json`
    ```json
    {"schemaVersion":1,"id":"app-beacon","name":"Beacon","description":"A small journal app.","developerIdentityId":"identity-studio","platforms":["macOS"],"websiteLinks":[{"id":"link-beacon","websiteId":"website-studio","purpose":"product","url":"https://example.com/beacon","isPrimary":true}]}
    ```

    `Websites/studio/record.json`
    ```json
    {"schemaVersion":1,"id":"website-studio","name":"Northstar Studio","owner":{"type":"identity","id":"identity-studio"},"baseURL":"https://example.com","blogEnabled":true,"blogIndexURL":"https://example.com/blog"}
    ```

    `SocialAccounts/studio-threads/record.json`
    ```json
    {"schemaVersion":1,"id":"account-studio-threads","platform":"threads","owner":{"type":"identity","id":"identity-studio"},"handle":"@northstar","enabled":true}
    ```

    `SocialAccounts/studio-mastodon/record.json`
    ```json
    {"schemaVersion":1,"id":"account-studio-mastodon","platform":"mastodon","owner":{"type":"identity","id":"identity-studio"},"profileURL":"https://example.com/@northstar","enabled":true}
    ```

    `Content/beacon-article/record.json`
    ```json
    {"schemaVersion":1,"id":"content-beacon-article","kind":"blog","title":"Meet Beacon","appIds":["app-beacon"],"websiteId":"website-studio","originalBodyPath":"article.md","includeSourceLink":false,"status":"draft","destinations":[],"mediaPaths":[]}
    ```

    `Content/beacon-article/article.md`
    ```markdown
    # Meet Beacon

    Beacon makes space for a short daily reflection.
    ```

    `Content/beacon-social/record.json`
    ```json
    {"schemaVersion":1,"id":"content-beacon-social","kind":"social","title":"Meet Beacon social posts","appIds":["app-beacon"],"sourceContentId":"content-beacon-article","originalBodyPath":"original.md","includeSourceLink":true,"status":"draft","destinations":[{"accountId":"account-studio-threads","status":"draft"},{"accountId":"account-studio-mastodon","bodyPath":"Variants/mastodon.md","status":"draft","mediaPaths":[]}],"mediaPaths":[]}
    ```

    `Content/beacon-social/original.md`
    ```markdown
    Meet Beacon: a little space for a daily reflection.
    ```

    `Content/beacon-social/Variants/mastodon.md`
    ```markdown
    We've made Beacon, a small journaling app for daily reflection. Here's the story behind it.
    ```

    The Threads destination inherits the original text. Mastodon uses its own file and an explicit empty media list. Editing that variant leaves the original and the Threads version intact. The social record points to the article; no reverse list needs updating. `includeSourceLink` does not itself publish either record.
    """#

    private static let skill = #"""
    ---
    name: indie-dev-buddy-content
    description: Create, organize, and adapt marketing drafts in an Indie Dev Buddy workspace using the validated indiedevbuddy CLI.
    ---

    # Indie Dev Buddy content

    Read `AGENTS.md` and run `indiedevbuddy --help`. Discover the workspace with `indiedevbuddy workspaces`, then use `list apps`, `list websites`, `list accounts`, and `list content` with `--workspace "$workspace"`. Choose eligible accounts and blog-enabled websites using their IDs.

    Create drafts with `indiedevbuddy create blog --workspace "$workspace" --title "Launch notes" --body-file draft.md`. Use `create social` for social drafts and pass `--account ID` for each destination. Use `--app ID`, `--website ID`, and `--source ID` as appropriate. Use the app for custom variants or media.

    Run `read content ID --workspace "$workspace"` to get the record, original body, and revisions. Pass `--revision` to `update`, plus `--body-revision` for body changes. If there is a conflict, reread and reconcile before retrying. The returned backup directory contains the previous bytes at their original workspace-relative paths. Run `validate --workspace "$workspace"` after changes.

    Keep drafts unpublished and preserve other variants and media. Prefer the CLI or app to direct JSON edits. Read `docs/DATA_FORMAT.md` and `docs/EXAMPLES.md` to understand the relationships and file layout.
    """#
}

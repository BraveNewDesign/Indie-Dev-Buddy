# MVP implementation plan and status

1. **File-backed foundation:** Select and reopen a workspace, index ordinary records, edit apps and owners, connect websites, and expose files. Validate persistence and conflicts.
2. **Marketing editor:** Configure social accounts, write articles and social originals, customize account versions, attach media, copy content, and record manual publication.
3. **Relationships and external edits:** Connect articles and social posts, resolve published links, show account previews and guidance, observe changes, and verify end-to-end workflows.

The product specification remains the acceptance authority. This file describes the implementation sequence; it is not a release-readiness claim.

## Implementation update — 2026-11-10

The current source now includes the SocialKit connection, account activity, Bluesky mention, and local scheduled-delivery workflows. API delivery uses a device-local journal to authorize intents, refreshes credentials near expiry when supported, preserves immutable scheduled payloads until the user explicitly reschedules with the current draft, and leaves ambiguous outcomes for manual reconciliation. Workspace account records distinguish editable display name/handle/profile URL and avatar from the verified provider recipient identity. Saved workspace avatars are used by account and composer previews. See [Social connections and local delivery](SOCIAL_CONNECTIONS.md) and the [GUI and CLI capability matrix](CLI_CAPABILITY_MATRIX.md).

This update reflects the checked-in source and documentation as of this date; no build, automated test, or live provider check was run for this documentation pass. The acceptance evidence below is dated 2026-11-06 and remains historical rather than a verification of these later social workflows.

**Current scope adjustment:** App release/version tracking is disabled in the UI, including version summaries, release views, and content-to-release links. Existing release files and legacy content references are preserved but are not loaded into the interface.

## Acceptance review — 2026-11-06

The code implements the three milestone slices, but the release gates in
`PRODUCT_SPEC.md` are not yet all verified. The checks below separate source and
automated evidence from the workflows observed in the running app.

- The workspace is file-backed and its editor uses revision checks. Related content
  saves preflight a batch and attempt rollback after an ordinary failure. This is
  best-effort recovery, not a crash-safe transaction or an atomic compare-and-swap
  against independent writers. Security-scoped bookmarks are stored in the app's
  Application Support plist, with a one-time migration from the earlier defaults
  storage. An earlier ad-hoc signed sandbox build stalled in
  `_libsecinit_appsandbox`; a fresh build on 2026-11-06 carried the expected sandbox
  and bookmark entitlements and launched to the Welcome screen. Its native workspace
  chooser remained inactive in the CUA session, with Create Workspace disabled, so
  selecting a fixture, persisting a bookmark, and reopening/relinking remain
  unverified.
- App, release, website, account, content, variant, media, preview, manual status,
  search, and file workflows exist. Rename and Trash are available for workspace
  descendants except store marker files; references to renamed or trashed asset paths
  are not rewritten. Search
  indexes record metadata rather than file contents. Category read failures now
  surface as actionable workspace load errors. The social composer has a compact
  Edit/Preview layout and warns when its linked source is unavailable. The running
  app visually confirmed the compact Edit/Preview layout and nonblocking over-limit
  warning. Blog content supports multiple app associations in the editor; model
  selection and persistence are covered by a focused test, while the updated control
  still needs live interaction verification. The Files view has manual refresh as a
  fallback for external changes.
- The focused macOS unit suite passed: 32 tests in 2 suites, covering compatibility,
  revisions, batch preflight/rollback, malformed records, relationships, category
  read errors, social destination eligibility, change observation, Files-browser
  path canonicalization, workspace file-operation scope, unique Codable website-link
  IDs with legacy decoding, import copy/no-replace behavior, symlink and destination
  rejection, workspace-load rejection of record paths outside the
  workspace, multi-app article associations, and preservation of disabled, ownerless,
  unresolved, and missing account references.
  A deterministic external-write interference test confirms partial rollback reports
  the affected path and preserves the outside writer's bytes.
  An explicit watcher test confirmed atomic Markdown and image replacements trigger
  workspace change notifications. A composer-state test also covers account eligibility
  refresh without a false dirty state.
  A fresh isolated unsigned Debug build and test-target build passed. The unit-test
  bundle from that same build was run directly with `xctest`: all 32 tests in 2
  suites passed. The UI-test target and runner built, but both unsigned and ad-hoc
  signed `xcodebuild test` attempts failed before launching the app: `testmanagerd`
  timed out while enabling automation mode, and Xcode reported that the UI-test
  runner failed to initialize. No app-under-test process appeared; this is a
  test-environment/automation failure, not an observed app test failure.
- In the running app against the explicit disposable fixture at
  `/tmp/indie-dev-buddy-ui-workspace`, observed checks covered the article/source
  relationship, three-account previews and effective length guidance, adding the
  source URL to preview text, saving an account-specific branch without changing the
  original or sibling branch, per-account media selection, manual publication state
  and URL, copy confirmation, unsaved-navigation cancellation, and external-edit
  conflict resolution. Returning a destination to the original body and creating a
  fresh custom branch left the old variant file intact. App icon import/save was
  verified. A staged icon plus externally edited app record produced the new Keep My
  Changes / Reload Workspace Copy choices: keeping local changes updated the expected
  revision and a later save succeeded while retaining the external description;
  reload discarded a local draft and showed the newer external repository URL.
  Source review found that website page identity was derived from editable fields,
  which gave same-site links duplicate SwiftUI IDs; IDs are now persisted and unique,
  with legacy records still decoding. In a cloned fixture, the running updated app
  saved three distinct product/support/privacy pages for Fixture App B and a product
  page for Fixture App C, both referencing the same website record. Renaming and
  saving Fixture App C in the updated app retained its page link after the save and
  snapshot refresh.
  Release Markdown notes and an imported release asset were saved and confirmed on
  disk. The valid fixture image loaded in the release editor; Copy Image followed by
  Paste Image created a second release asset. The release unsaved-navigation prompt
  preserved a local draft after choosing Keep Editing. The Files browser opened the
  fixture Inbox and created, renamed, and moved a disposable folder to the Trash. It
  also created, renamed, and trashed a disposable folder under `Content`; the folder
  disappeared from the listing. A native file-picker import attempt stalled before
  completion. The Files browser now uses SwiftUI's file importer with generic data
  types and copy/no-replace handling.
  The updated app opened the fixture Inbox through an accessible folder button. During
  the latest picker attempt, disposable `.txt` and image files in `/tmp` appeared in
  the panel, but its Open button remained disabled and the panel was inactive in the
  CUA session; no file was imported. Unit tests cover the copy and safety rules, while
  native picker completion remains unverified. A later Files browser check against
  the updated build also confirmed `/tmp` workspace paths resolve correctly when macOS reports
  the root as `/private/tmp`; the browser still excludes symlinks. Drag-and-drop
  media and keyboard/accessibility behavior remain unverified. An earlier Paste Image
  attempt with an unsupported clipboard item produced its actionable error. Content
  media files can remain unreferenced if a user cancels after importing them; cleanup
  is deliberately not implicit.
- A further updated-build UI check renamed and saved a newly selected app record
  while the workspace snapshot was refreshing; the record remained editable, and
  its website page remained visible after save. This covers the transient missing
  snapshot entry that previously caused a false revision conflict.
- The updated running app's Social Accounts list showed the owner under each account.
  Its owner filter offered identity and app owners, and filtering to Fixture Person
  showed only the account assigned to that identity.
- Workspace refreshes carry a generation into the open content editor. It checks the
  record, original body, and account-variant revisions; clean drafts reload after
  external changes, while dirty drafts retain local edits and show Keep/Reload choices.
  Running-app verification against `/tmp/indie-dev-buddy-website-links-fixture` confirmed
  that an atomic external Markdown edit updates the open article while keeping both the
  Marketing Content section and article selected. An external edit with a local draft
  open showed the conflict choices; Cancel kept the local draft and editor open. Root
  navigation and selected content are persisted through app storage so a refreshed
  content view recovers the active workflow. The later explicit Keep My Local Changes
  choice allowed a subsequent save to replace the fixture's external version.
- A running-app composer check selected a customized Threads account and entered 650
  characters. With the linked article URL included, the preview reported 691 / 500
  and showed its warning. Save Changes persisted all 650 characters to the account's
  variant file, and Copy Text reported success; the clipboard contained the 691
  character effective text ending in the article URL. The same compact composer
  displayed its Edit/Preview switch when its available width was below the wide layout
  threshold.
- In the running app, a valid external edit to the Example App JSON changed its sidebar
  name without restarting. A malformed replacement produced an expanded, file-specific
  workspace issue with the decode error; restoring the valid record cleared the issue.
- A running-app eligibility check disabled a referenced Threads account in the fixture.
  It left the post's destination file intact, removed the account from the selected
  count, and showed an unavailable-account warning. Re-enabling it made it available
  again without silently reselecting it.
- The social composer now reconciles open selections when account eligibility changes:
  an account that becomes unavailable is removed from selected state, remains in the
  preserved destination set, and does not by itself make a clean draft appear dirty.
  This behavior is covered by the running-app check above and by a focused unit test.
- In the running app, renaming and saving the article retained its source relationship
  to the social post. Moving the article's folder while the workspace was open also
  preserved the relationship; opening the article navigated to its new folder and
  loaded its title and body.
- A running-app check found that the social composer could cause its HSplitView detail
  pane to collapse. The detail editor now requests a 520-point minimum width. In the
  updated isolated build, creating a new social post opened the composer with its title,
  shared-text editor, media controls, eligible destination accounts, preview guidance,
  and Save Changes action visible. The focused 29-test unit suite passed after this fix.
- Review of Nov 5 live-refresh fixture crash reports found repeated SwiftUI
  `BindingOperations.ForceUnwrapping` traps while the content editor was mounted. The
  non-social editor no longer projects a binding through optional `edited` state; it
  uses a stable binding that falls back to the selected record during reload transitions.
  A fresh Debug build passed. Xcode's scheme test action stalled during test-log
  finalization without producing a result bundle, but its newly built unit-test bundle
  ran directly with `xctest`: all 29 tests in 2 suites passed after the binding change.
  The Xcode bridge then launched the project app and reported its process running. The
  desktop's stale crash dialogs exposed an XCTest system prompt requesting Touch ID or a
  password to enable UI automation. I did not provide or bypass those credentials; CUA
  requests for Indie Dev Buddy time out, so the crash and reload transition could not be
  rechecked live.
- Generated workspace `AGENTS.md` includes required fields, examples for each record
  type, ID-based relationships, path bases, and external-edit/conflict guidance. A
  guide read from the older disposable UI fixture contains only the original brief
  instructions; existing workspaces are not silently rewritten. The generation
  contract is checked by `generatedWorkspaceGuideDescribesCurrentPathBasesAndSchema`.
- Still required for full acceptance: live crash/reload/navigation verification after
  the optional-binding change; the signed sandbox workspace selection,
  bookmark persistence, restart, and relink workflow; externally edited image refresh;
  native file browser import; record-folder and referenced-asset operation checks;
  drag-and-drop media; and the full empty-state, keyboard, and accessibility pass.
  Markdown refresh in the open clean and dirty editors and article relationship
  stability after title/folder changes are verified as described above. The build emitted Xcode's App
  Intents metadata-skip warning because the target has no AppIntents framework
  dependency; it did not prevent the build or test run.

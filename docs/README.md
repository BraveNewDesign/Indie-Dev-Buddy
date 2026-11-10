# Indie Dev Buddy — Agent Pack

Use `PRODUCT_SPEC.md` as the **source of truth** and `AGENT_START_PROMPT.md` as the initial instruction to your Xcode AI coding agent. This pack is in the repository's `docs/` directory. Paths to the existing Xcode project and source below are relative to the repository root: project `Indie Dev Buddy.xcodeproj`, app sources `Indie Dev Buddy/`, unit tests `Indie Dev BuddyTests/`, and UI tests `Indie Dev BuddyUITests/`. `DESIGN_REFERENCE.png` shows the latest visual concept; it is **not** a pixel-accurate contract, and any decorative, simulated publishing/scheduling actions must be interpreted according to the spec.

Attach the files in this folder in the coding agent's context and send the start prompt. Implement milestone by milestone; verify the end-to-end acceptance checks before calling the app finished.

## Workspace command-line tool

Build the **Indie Dev Buddy** scheme to include `indiedevbuddy` in the app bundle. Choose **Indie Dev Buddy → Install Command-Line Tool…** to create a link in `~/.local/bin`. The installer shows the shell configuration line if you need to add that directory to your PATH. If you move the app after installing, remove the old link and rerun the installer from the new location.

```sh
indiedevbuddy --help
indiedevbuddy workspaces
indiedevbuddy list content --workspace "$workspace"
indiedevbuddy create blog --workspace "$workspace" --title "Launch notes" --body-file draft.md
indiedevbuddy read content "$id" --workspace "$workspace"
indiedevbuddy update "$id" --workspace "$workspace" --revision "$revision" \
  --body-file revised.md --body-revision "$body_revision"
indiedevbuddy save-record accounts "$account_id" --workspace "$workspace" \
  --record-file account.json --revision "$revision"
indiedevbuddy delete content "$id" --workspace "$workspace" --revision "$revision"
indiedevbuddy files --workspace "$workspace" --path Content
indiedevbuddy mkdir --workspace "$workspace" --path Inbox/Research
indiedevbuddy import-file --workspace "$workspace" --source notes.pdf --path Inbox/Research/notes.pdf
indiedevbuddy rename --workspace "$workspace" --path Inbox/Research/notes.pdf --name brief.pdf
indiedevbuddy trash --workspace "$workspace" --path Inbox/Research/brief.pdf --confirm yes
indiedevbuddy validate --workspace "$workspace"
```

Use the path from `workspaces` and the ID and revisions from `read`. The app can register an existing workspace by opening it once. If macOS restricts access to the previous sandbox's registry, open the workspace again to register it for this build.

`read` returns the complete record and its revision. For content it also returns the original body and body revision, plus `relatedFiles` entries for destination variants and media with their workspace-relative paths and revisions. Text variants include their text; binary media include the hash only.

`save-record <category> ID --record-file FILE` creates a model record when there is no `--revision`. To edit an existing record, pass the current record revision from `read`. The JSON must contain the same stable UUID as `ID`; model fields, relationships, statuses, URLs, and referenced assets are validated before persistence. For content, pair each `--file WORKSPACE_PATH=SOURCE_FILE` with `--file-revision WORKSPACE_PATH=HASH` (or `new` for a new path). File writes are limited to paths referenced by the new content record and are batched atomically with its record update. This supports destination and account changes, per-destination status, publication URL/date, body variants, media references, and media payload replacement. The output returns the changed record, new record revision, changed related file revisions, and a `backupDirectory` for updates. `delete <category> ID --revision HASH` permanently deletes that record's folder and requires the latest revision; inspect the ID with `list`/`read` before using it.

`files` lists one workspace folder at a time and returns regular-file revisions. All file paths are relative to the workspace. `import-file` refuses to overwrite and accepts regular files only. `rename` stays in the same folder. `trash` follows the GUI's reversible Trash action and requires `--confirm yes`; `remove` is permanent and also requires explicit confirmation. Both protect workspace marker files, reject symbolic links, and enforce workspace containment. `create-workspace PATH` creates the standard layout and registers it; `register-workspace PATH` validates and registers an existing workspace; `forget-workspace PATH` removes only the app's registration, leaving workspace files intact.

All commands return JSON on stdout; errors return JSON on stderr and exit nonzero. Validation issues return JSON and exit 2. Backups mirror the replaced paths under the returned backup directory. `CLI_CAPABILITY_MATRIX.md` lists GUI and CLI coverage, including current limitations. The CLI does not schedule or publish to external services. The app stores per-destination schedule metadata separately from the content status enum, and the app's device-local delivery journal is required to authorize local API delivery.

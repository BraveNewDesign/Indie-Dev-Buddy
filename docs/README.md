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
indiedevbuddy validate --workspace "$workspace"
```

Use the path from `workspaces` and the ID and revisions from `read`. The app can register an existing workspace by opening it once. If macOS restricts access to the previous sandbox's registry, open the workspace again to register it for this build.

Updates accept the title and original body. Validation checks the manifest, supported record categories, their relationships, and referenced bodies and assets. Each update returns a backup directory containing the previous bytes of the files it replaced, arranged by their original workspace-relative paths. Recover a draft by using those files as input for an update against its current revisions. The GUI and CLI coordinate their saves. Each file is replaced atomically, and the backups also allow recovery if a process stops during a multi-file update.

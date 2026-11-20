---
title: Workspace Command-Line Guide
nav_order: 5
permalink: /cli-guide/
---

# Workspace command-line guide

The bundled `indiedevbuddy` command-line tool lets you inspect and edit workspace data from Terminal or scripts. It operates on files in the workspace you specify. It does not connect social accounts, schedule delivery, or publish externally.

## Install the command

In the installed app, choose **Indie Dev Buddy → Install Command-Line Tool…** to create a link in `~/.local/bin`. The installer shows how to add that directory to your shell's `PATH` if needed. If you move the app, remove the old link and install again from the moved app. When building from source, build the **Indie Dev Buddy** scheme to include the command in the app bundle.

Start with:

```sh
indiedevbuddy --help
indiedevbuddy workspaces
```

The `workspaces` output lists registered workspace paths. An existing workspace can be registered by opening it once in the app, or with `register-workspace`.

## Read and edit content

For example, set `workspace` to a path returned by `workspaces`, then list your content:

```sh
workspace="$HOME/Documents/My Indie Workspace"
indiedevbuddy list content --workspace "$workspace"
```

Choose a content record ID from the JSON output and assign it to `content_id`. Read that record, then copy its record revision and body revision into `revision` and `body_revision`. Replace the example values below with the values from your output; `revised.md` is a local plain-text file containing the replacement body.

```sh
content_id="REPLACE_WITH_CONTENT_ID"
indiedevbuddy read content "$content_id" --workspace "$workspace"
revision="REPLACE_WITH_RECORD_REVISION"
body_revision="REPLACE_WITH_BODY_REVISION"
indiedevbuddy update "$content_id" --workspace "$workspace" --revision "$revision" \
  --body-file revised.md --body-revision "$body_revision"
```

Read the record again before another edit to get its new revisions. To create a blog draft instead, use `indiedevbuddy create blog --workspace "$workspace" --title "Launch notes" --body-file draft.md`.

Use `save-record` when you need to change the full model, such as account associations, destinations, publication metadata, or account records. Save the JSON from `read` to a file, edit it, and pass the current revision:

```sh
indiedevbuddy save-record accounts "$account_id" --workspace "$workspace" \
  --record-file account.json --revision "$revision"
```

For a new model record, omit `--revision`. The JSON must contain the same stable UUID as the requested ID. For content media or destination text files, pair every `--file WORKSPACE_PATH=SOURCE_FILE` with its current `--file-revision WORKSPACE_PATH=HASH`; use `new` for a path that does not exist yet. `read` returns related file paths and revisions.

## Work with workspace files

All file paths are relative to the workspace. `import-file` copies a regular file and refuses to overwrite. `rename` stays within one folder. `trash` is reversible; `remove` permanently deletes and requires confirmation.

Use the app's Asset Library to change files under `Shared Files/Asset Library`. The library tracks assets by ID so they can be reused in content and screenshot sets. `validate` checks that the library index is readable, indexed files exist, and screenshot sets refer to indexed assets. Use the app to check screenshot readiness, including image dimensions and counts.

```sh
indiedevbuddy files --workspace "$workspace" --path Content
indiedevbuddy mkdir --workspace "$workspace" --path Inbox/Research
indiedevbuddy import-file --workspace "$workspace" --source notes.pdf --path Inbox/Research/notes.pdf
indiedevbuddy rename --workspace "$workspace" --path Inbox/Research/notes.pdf --name brief.pdf
indiedevbuddy trash --workspace "$workspace" --path Inbox/Research/brief.pdf --confirm yes
indiedevbuddy validate --workspace "$workspace"
```

Workspace commands include `rename-workspace --workspace PATH --name NAME` to change the name shown in Indie Dev Buddy without moving the folder:

```sh
indiedevbuddy rename-workspace --workspace "$workspace" --name "Studio Workspace"
```

Setup commands include `create-workspace PATH`, `register-workspace PATH`, and `forget-workspace PATH`. Forgetting a workspace removes its app registration, not its files.

## Manage workspace agent guidance

In the app, select **Agent Guidance…** in the workspace switcher. Review workspace instructions, skill packages, and shipped references. **Additional Instructions** writes a marked section in the workspace's `AGENTS.md` after you approve the preview. If that file was customized outside the app, the preview shows your existing text with the new section appended. The current built-in instructions are available separately for comparison.

`guidance` is read-only and returns each file's current text, status, path, and revision where available. It includes proposed replacement text for missing or recognized outdated built-ins. Review it before running `guidance-update --path RELATIVE_PATH --revision HASH`, using `new` when the file is missing. Customized files are preserved. New workspaces receive shipped guidance, and opening older workspaces adds missing built-ins when possible. Refreshing the view reads the workspace without installing guidance.

Preview additional instructions by omitting `--apply`. Review the returned `before` and `after` fields, then repeat the command with the same revision and body and add `--apply yes`. An empty body clears the additional section. Use `--revision new` if `AGENTS.md` is missing.

```sh
indiedevbuddy guidance --workspace "$workspace"
indiedevbuddy guidance-instructions --workspace "$workspace" --revision "$revision" --body-file instructions.md
indiedevbuddy guidance-import --workspace "$workspace" --source ./studio-style
indiedevbuddy guidance-archive --workspace "$workspace" --skill studio-style --revision "$skill_revision"
indiedevbuddy guidance-restore --workspace "$workspace" --skill studio-style --revision "$archived_revision"
```

Import copies a local folder with `SKILL.md` and its supporting files into `.agents/skills`. Archive moves a whole skill folder into `.indie-dev-buddy/archived-skills` so it stays disabled across reopen. Restore moves it back without overwriting any active folder with the same name. Review any custom instructions that refer to an archived skill. Review a skill's source and contents before relying on it.

## Output and safety

Commands return JSON on stdout. Errors return JSON on stderr and a nonzero exit status; validation issues return status 2. Updates use revision checks, validate model data, and create backups. Stale revisions are conflicts: read the latest record and decide whether to reapply your change.

The CLI rejects symbolic links and paths outside the workspace, protects marker files, and requires explicit confirmation for trash or permanent removal. Inspect IDs and revisions with `list` and `read` before modifying records. `delete <category> ID --revision HASH` permanently deletes a record and its folder.

For app-versus-CLI coverage and delivery limitations, see the [GUI and CLI capability matrix]({{ '/cli-capability-matrix/' | relative_url }}). Agent-oriented schema and project instructions live in the [AI agent development pack]({{ '/agent-pack/' | relative_url }}).

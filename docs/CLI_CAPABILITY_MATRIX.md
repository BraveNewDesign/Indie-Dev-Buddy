# Workspace GUI and CLI capability matrix

This matrix compares workspace operations exposed by the macOS UI with the CLI in this checkout. Record IDs are stable model IDs; folder names remain implementation paths only.

| GUI workspace operation | CLI coverage | State |
|---|---|---|
| List/read identities, apps, websites, social accounts, and content | `list`, `read` by category and record ID | Supported |
| Create blog, social, and idea drafts with app/site/source/account associations | `create` | Supported |
| Edit content title and original body | `update` with record and body revisions | Supported |
| Add/remove destinations; change account association; change each destination status, publication URL/date; change content metadata and shared media references | `save-record content ID` with the full record JSON and current record revision | Supported |
| Create/change destination body variants | `read` returns file revisions; `save-record --file PATH=SOURCE --file-revision PATH=HASH` writes variants with the record in one batch | Supported |
| Import/replace content media files and account-specific media | Add paths to the record and pair each content `--file` write with `new` or the current file revision; remove references by saving the updated record | Supported for content-referenced assets; unreferenced workspace file actions remain unavailable |
| Create/edit/delete identity, app, website, and account records; toggle account enabled state | `save-record` creates without `--revision` and updates with current `--revision`; `delete` requires current revision | Supported, with model validation |
| Delete content | `delete content ID --revision HASH` removes the record folder | Supported |
| Create a related social post from a blog article | `create social` with `--source ID`, `--app ID ...`, and chosen title/body | Supported; the agent supplies the desired draft text |
| Browse workspace folders; create folders; import files; rename and move items to Trash | `files`, `mkdir`, `import-file`, `rename`, and `trash` (explicit `--confirm yes`) | Supported with workspace-relative path and symlink checks |
| Permanently delete a workspace file or folder | `remove` with `--confirm yes` | Supported; permanent removal is extra CLI capability beyond GUI Trash |
| Create/register, register existing, list, or forget a workspace | `create-workspace`, `register-workspace`, `workspaces`, and `forget-workspace` | Supported; forgetting only removes the app registry entry and keeps files |
| Switch the open workspace and resolve unsaved editor navigation | CLI commands take an explicit `--workspace PATH`; stale revisions return JSON conflicts for the agent to reread and retry | CLI has no open-editor selection or unsaved GUI draft state |
| Open/reveal project, repository, app store, and website URLs; copy text/images; show previews and eligibility guidance | GUI-only navigation, clipboard, and presentation actions | **GUI-only by design**; they do not mutate workspace records |
| Schedule or publish externally | Neither CLI nor current workspace model performs external scheduling/publishing; statuses are `idea`, `draft`, `ready`, and `published` | No scheduled status exists; do not represent scheduled work as published |

`save-record` replaces model JSON and any supplied referenced content files through `WorkspaceStore` validation, atomic replacement, revision conflict checks, and backup creation. Open/reveal in Finder and UI-only previews/clipboard actions remain GUI-only because they do not edit workspace data. External scheduling and publishing are intentionally absent from both products' current data model and CLI.

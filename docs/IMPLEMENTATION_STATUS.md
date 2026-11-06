# MVP implementation plan and status

1. **File-backed foundation:** Select and reopen a workspace, index ordinary records, edit apps and owners, connect websites, and expose files. Validate persistence and conflicts.
2. **Marketing editor:** Configure social accounts, write articles and social originals, customize account versions, attach media, copy content, and record manual publication.
3. **Relationships and external edits:** Connect articles and social posts, resolve published links, show account previews and guidance, observe changes, and verify end-to-end workflows.

The product specification remains the acceptance authority. This file describes the implementation sequence; it is not a release-readiness claim.

## Acceptance review — 2026-11-05

The code implements the three milestone slices, but the release gates in
`PRODUCT_SPEC.md` are not yet all verified. In particular:

- The workspace is file-backed and its editor uses revision checks. Related content
  saves preflight a batch and attempt rollback after an ordinary failure. This is
  best-effort recovery, not a crash-safe transaction or an atomic compare-and-swap
  against independent writers.
- App, release, website, account, content, variant, media, preview, manual status,
  search, and file workflows exist. File rename and Trash are limited to Inbox and
  Shared Files; other workspace paths can be opened or revealed in Finder. Search
  currently indexes record metadata rather than file contents.
- A compact layout for the social preview still needs work against the specification.
  The Files view has a manual refresh as a fallback for external changes.
- Unit tests cover record compatibility, revisions, batch rollback, malformed
  records, relationships, and change observation. A running-app check reopened a
  temporary workspace, navigated from an article to its related social post, searched
  for an app, and created a test folder. These checks do not establish the remaining
  release gates.
- Still required: a signed sandbox/bookmark restart and relink check; a complete
  multi-account branching, media paste/drop, preview/copy, publication and source-link
  workflow; external edits while a local draft is dirty; and keyboard/accessibility
  verification. The macOS UI-test runner stalled during the latest attempt, so it
  does not provide a passing result.

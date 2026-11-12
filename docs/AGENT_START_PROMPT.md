---
title: AI Agent Start Prompt
nav_order: 8
permalink: /agent-start-prompt/
---

# Build instruction for AI coding agent

Implement the **Indie Dev Buddy** macOS SwiftUI MVP described in the attached `PRODUCT_SPEC.md`. Treat it as the source of truth for product behavior, information architecture, file storage, and release gates. The accompanying visual mockup is conceptual UI direction only; prioritize native Mac usability, discoverability, and working end-to-end workflows over pixel matching.

Start by opening the existing project at `Indie Dev Buddy.xcodeproj` (relative to the repository root). App source is in `Indie Dev Buddy/`, unit tests are in `Indie Dev BuddyTests/`, and UI tests are in `Indie Dev BuddyUITests/`. Inspect and build on this code; create a new macOS SwiftUI project only if the existing project is missing or unusable. Do not treat `DerivedData/` as source. Implement in the spec's milestone order. Keep the codebase small, local-first, and file-backed: JSON + Markdown/plain text + assets in a user-selected folder, no database/server/MCP/social publishing integrations. Do not expand scope into project management, analytics, or an AI feature.

Critical workflows to get right: a shared website can supply product/support/privacy pages to many apps; social accounts have visible ownership and only configured/enabled accounts are eligible; one original post can be used across several accounts with optional independent versions; a long blog article can be the source of related social drafts; platform-inspired previews and character guidance warn without blocking; all copy/media/save/mark-published actions work; linked Xcode/changelog locations are references rather than copied projects; agent-made file edits appear in the UI safely.

Design for a first-time user: explicit sidebar labels, stable app and content views, prominent creation actions, sensible empty states, obvious account ownership, and no hidden essential commands. Avoid fake actions: the app prepares content but does not actually publish it to social networks or websites.

Deliver one functional milestone at a time, build and test each stage, and run through every applicable acceptance criterion in `PRODUCT_SPEC.md` before declaring completion. If a requirement is impractical in the current pass, describe the limitation clearly rather than leaving inert controls or silently dropping data. Keep a concise progress/decision log, and maintain the workspace's `AGENTS.md` schema instructions and sample records for external agents.

## Documentation maintenance

When a code change alters user-visible behavior, setup, or a CLI capability, update the relevant Markdown source in `docs/` in the same change. Keep `PRODUCT_SPEC.md` authoritative for intended behavior and update `IMPLEMENTATION_STATUS.md` only when the checked-in implementation status materially changes. Documentation pages are built from Markdown with Jekyll and Just the Docs; use each page's front matter for its title, navigation order, and stable URL. Do not edit generated `_site/` files or add custom theme styling for routine documentation changes. Follow `CONTRIBUTING.md` for previewing the site and submitting documentation updates for review.

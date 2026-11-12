---
title: AI Agent Development Pack
nav_order: 9
permalink: /agent-pack/
---

# AI agent development pack

This section is for coding agents working on the Indie Dev Buddy repository. It is separate from the [workspace CLI guide]({{ '/cli-guide/' | relative_url }}), which explains practical commands for app users and workspace editors.

## Current project references

- [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) defines intended product behavior and scope.
- [`AGENT_START_PROMPT.md`](AGENT_START_PROMPT.md) is the historical initial MVP coding prompt. It predates later scope changes and should not be used alone as current implementation instructions.
- [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) is a dated engineering record with historical verification notes, not a current release-readiness claim.
- [`CLI_CAPABILITY_MATRIX.md`](CLI_CAPABILITY_MATRIX.md) describes workspace GUI and CLI coverage.
- The root [`CONTRIBUTING.md`](../CONTRIBUTING.md) describes pull requests and code changes.

Before changing code, inspect the checked-in implementation and applicable workspace `AGENTS.md`. Preserve uncommitted changes, use the current product specification for scope, and update user-facing docs when behavior or supported commands change. Do not copy credentials, generated build output, or private workspace data into repository files.

## Original start prompt

The original prompt is retained for historical context. For a new development task, follow the current task request, repository instructions, `PRODUCT_SPEC.md`, and checked-in behavior. Review the [historical prompt]({{ '/agent-start-prompt/' | relative_url }}) before reuse because it includes superseded MVP assumptions.

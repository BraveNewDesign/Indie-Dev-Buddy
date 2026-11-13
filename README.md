<p align="center">
  <img src="docs/assets/app-icon.png" alt="" width="120">
</p>

<h1 align="center">Indie Dev Buddy</h1>

<p align="center">
  A little more organization for everything that comes after making an app.
</p>

<p align="center">
  <a href="https://github.com/BraveNewDesign/Indie-Dev-Buddy/releases/latest"><strong>Download for Mac</strong></a> ·
  <a href="https://bravenewdesign.github.io/Indie-Dev-Buddy/documentation/">Documentation</a> ·
  <a href="https://github.com/BraveNewDesign/Indie-Dev-Buddy/issues">Report an issue</a>
</p>

![Indie Dev Buddy workspace showing an app library and upcoming posts](docs/screenshots/marketing/workspace.webp)

Indie Dev Buddy brings your apps, websites, marketing drafts, social accounts, and App Store Connect information together in one Mac app. Keep track of the details, plan what to share, and spend more time making things.

Your workspace lives in a folder you choose. You can use the app on its own, or work with the same files through its command-line tool and AI coding agents. There is no hosted account or cloud scheduler.

**Early access** · Apple silicon · macOS 27.2 or later · [MIT licensed](LICENSE)

## Get started

1. [Download the latest release](https://github.com/BraveNewDesign/Indie-Dev-Buddy/releases/latest), open the DMG, and drag Indie Dev Buddy to Applications.
2. Open the app and create a workspace, or choose an existing one. Pick a folder you can access and back up.
3. Add an app or website, then create a draft or connect a social account when you're ready.

The app is signed and notarized and checks for updates through Sparkle. For a walkthrough, see [Getting started](docs/GETTING_STARTED.md).

## Everything in its place

### Organize your projects

Keep app descriptions, icons, development status, bundle IDs, project folders, repositories, and App Store and TestFlight links together. Add websites and related product, support, and privacy pages. Browse and manage workspace files, switch between workspaces, and see changes made outside the app.

### Plan and share your work

Write articles, social posts, and ideas in Markdown. Organize them in a calendar or board, link them to your apps and websites, and turn an article into a social post. Start with one post, customize the text and media for each account, and preview it before sharing.

![Content board organizing ideas through drafts, posts to share, and published work](docs/screenshots/marketing/content-board.webp)

Connect supported accounts to publish or schedule from the app, or use manual planning and copy your content to publish elsewhere:

- **Connected publishing:** Bluesky, Facebook Pages, Threads, Instagram, X, LinkedIn, and Mastodon.
- **Manual planning:** GitHub accounts and custom platforms.

Where a provider permits it, you can also review account activity and interact with posts or comments. Availability depends on the provider, account setup, and permissions. See [Social connections](docs/SOCIAL_CONNECTIONS.md) for setup and supported actions.

> **Scheduled posts run on your Mac.** Indie Dev Buddy must be open and your Mac awake at the scheduled time. Manual schedules are reminders and don't send posts. The app keeps delivery history for reviewing completed, missed, or uncertain attempts.

### Stay close to App Store Connect

Link a workspace app to App Store Connect to see version and build status, review information, listing details, customer reviews, TestFlight feedback, available analytics, and screenshots. You can import selected screenshots into your workspace and prepare release notes or marketing drafts from “What's New” text or a Git reference.

![App library with App Store Connect customer reviews and TestFlight feedback](docs/screenshots/marketing/app-store-connect.webp)

This integration requires the `asc` command-line tool to be installed and authenticated. App Store Connect access is read-only: the app does not upload metadata or screenshots, submit versions, or reply to reviews. Analytics depend on available reports and the permissions of your active `asc` profile.

### Keep assets ready to use

Organize reusable images in an asset library with folders and tags. Create screenshot sets by app, platform, language, and version; reorder images and check their dimensions and display coverage. You can also make a shareable image of your app lineup, with a choice of layouts, appearance, headings, and studio details.

![App showcase editor alongside a preview of an app lineup](docs/screenshots/marketing/app-showcase.webp)

## Your workspace, your tools

Workspace records are ordinary files in the folder you choose. Social account credentials are stored separately in macOS Keychain, rather than in those records. Back up your workspace folder as you would any other important project.

Indie Dev Buddy also includes `indiedevbuddy`, a command-line tool for people, scripts, and AI agents. It returns structured JSON and can inspect and manage workspace records, drafts, files, and workspaces. Revision checks and validation help catch stale edits and missing asset references. The CLI manages workspace data; connecting accounts, scheduling, and publishing happen in the app.

Each workspace includes agent guidance, data-format references, examples, and a marketing content skill. Agents can use their existing terminal tools—there's no MCP server to set up.

- [Command-line guide](docs/CLI_GUIDE.md)
- [App and CLI capability matrix](docs/CLI_CAPABILITY_MATRIX.md)
- [AI agent development pack](docs/README.md)

## Build from source

Building requires Xcode 27.2 or later. Open `Indie Dev Buddy.xcodeproj` in Xcode and build the **Indie Dev Buddy** scheme. The project uses the public [SocialKit](https://github.com/BraveNewDesign/SocialKit) package; Xcode resolves the dependency when opening the project.

See [Direct distribution](docs/DIRECT_DISTRIBUTION.md) for release packaging and Sparkle update setup.

## Learn more and contribute

- [Documentation website](https://bravenewdesign.github.io/Indie-Dev-Buddy/documentation/)
- [Getting started](docs/GETTING_STARTED.md)
- [Social account setup and publishing](docs/SOCIAL_CONNECTIONS.md)
- [Contributing guide](CONTRIBUTING.md)
- [Social icon sources and attribution](docs/SOCIAL_ICON_SOURCES.md)

Bug reports, ideas, code changes, and documentation improvements are welcome. Please use [GitHub issues](https://github.com/BraveNewDesign/Indie-Dev-Buddy/issues) to report a problem or start a discussion.

## License

Indie Dev Buddy is available under the [MIT License](LICENSE). Third-party artwork and platform marks remain subject to their respective licenses and brand guidelines. Indie Dev Buddy is not affiliated with or endorsed by Apple or the social platforms it supports.

---
title: Getting Started
nav_order: 1
permalink: /getting-started/
---

# Getting started

Indie Dev Buddy is a local-first Mac app for organizing app and website records, drafting marketing content, and managing supported social connections. Workspace records are ordinary files in a folder you choose. The app does not require a hosted account or cloud workspace.

## Install and open

Download the signed Apple silicon build from [GitHub Releases](https://github.com/BraveNewDesign/Indie-Dev-Buddy/releases/latest), open the DMG, and drag Indie Dev Buddy to Applications. The current release requires macOS 27.2 or later. The app checks for updates through Sparkle.

## Create a workspace

On first launch, create a workspace or open an existing one. The workspace is a folder on your Mac containing app, website, identity, social account, and content records. Use a folder you can access and back up. Opening a workspace registers it with the app on this Mac.

Add an app or website record to keep project links together. Add social accounts under **Websites & Social Accounts → Social Accounts**; account records hold editable profile details, while provider credentials are kept in the macOS Keychain.

## Draft content

Create an article or social draft in the content area. A social post can have account-specific text and media while retaining its shared original. You can link a social draft to a source article and associate content with one or more apps. Use previews to inspect destination-specific text and media before copying or scheduling.

For a manual post, choose **Manually Scheduled** to record a date. This does not send anything: copy the text, open the destination, publish there, then update its status in the app. To use API delivery, connect a supported account and choose **Scheduled on This Mac**. The app must be running and the Mac awake at the due time. See [Social connections]({{ '/social-connections/' | relative_url }}) for supported providers and delivery details.

## Optional integrations

- App Store Connect access uses your installed and authenticated `asc` command-line tool. The app can read release status and prepare editable text, but its ASC actions are read-only.
- Social account connection and API publishing depend on provider access, permissions, and supported media formats. Credentials stay in the Mac's Keychain.
- The [workspace CLI guide]({{ '/cli-guide/' | relative_url }}) covers Terminal operations. The CLI does not schedule or publish posts.

## More help

- [Social connections and local delivery]({{ '/social-connections/' | relative_url }})
- [Workspace command-line guide]({{ '/cli-guide/' | relative_url }})
- [GUI and CLI capability matrix]({{ '/cli-capability-matrix/' | relative_url }})
- [Troubleshooting and project issues on GitHub](https://github.com/BraveNewDesign/Indie-Dev-Buddy/issues)

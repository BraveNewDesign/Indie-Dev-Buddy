# Indie Dev Buddy

Indie Dev Buddy is a local-first macOS workspace for indie software makers to organize apps, releases, marketing content, and social publishing.

**Status:** early access. This release is a local Mac app; it has no hosted account service or cloud scheduler.

## Download

Download the signed, notarized Apple silicon build from [GitHub Releases](https://github.com/BraveNewDesign/Indie-Dev-Buddy/releases/latest). Open the DMG and drag Indie Dev Buddy to Applications. Requires macOS 27.2 or later. The app checks for updates through Sparkle.

## What it does

- Organize app and website records, ideas, release information, and marketing content in a workspace folder of ordinary files.
- Draft social posts and account-specific variants, attach media, and track publication status.
- Connect supported social accounts through SocialKit and publish through their APIs when the required account access is configured.
- Optionally use the `asc` command-line tool to find App Store Connect apps, read release and review status, and pull release text into an editable draft.
- Use the bundled `indiedevbuddy` command-line tool for workspace operations from Terminal and coding agents.

## What to expect

- You configure provider access and account permissions. Meta setup is documented in [Social connections](docs/SOCIAL_CONNECTIONS.md).
- Provider credentials are stored in the macOS Keychain. Workspace records contain social account metadata, not provider tokens.
- Scheduled API delivery is local to the Mac. Indie Dev Buddy does not provide a cloud scheduler or guarantee delivery while the Mac is asleep or the app is unavailable.
- The App Store Connect integration requires the separate `asc` CLI to be installed and authenticated. Its ASC actions are read-only; release text can be pulled into an editable, copyable draft, but the app does not upload it or submit builds for review.
- Indie Dev Buddy is not affiliated with or endorsed by Apple, Meta, Bluesky, Mastodon, LinkedIn, X, or GitHub.

## Build

The released app currently supports Apple silicon and requires macOS 27.2 or later. Building from source requires Xcode 27.2 or later. Open `Indie Dev Buddy.xcodeproj` in Xcode and build the **Indie Dev Buddy** scheme.

The project depends on the public SocialKit package at version 0.1.0. Publish the matching `v0.1.0` SocialKit tag before building a fresh clone.

The direct-download release path and Sparkle update setup are documented in [Direct distribution](docs/DIRECT_DISTRIBUTION.md).

## Documentation

- [Social account setup and publishing behavior](docs/SOCIAL_CONNECTIONS.md)
- [Agent pack and command-line tool](docs/README.md)
- [Social icon sources and attribution](docs/SOCIAL_ICON_SOURCES.md)
- [Workspace product specification](docs/PRODUCT_SPEC.md)

## License

Indie Dev Buddy is licensed under the [MIT License](LICENSE). Third-party artwork and platform marks remain subject to their respective licenses and brand guidelines; see the icon source notes in this repository.

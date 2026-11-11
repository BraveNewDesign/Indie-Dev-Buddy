# Direct macOS distribution

The open-source build is distributed outside the Mac App Store. Sparkle checks
for updates from `docs/appcast.xml`; GitHub Pages publishes the feed, while the
versioned update archives are kept under `docs/updates/`. The initial installer
DMG and source release can be attached to GitHub Releases.

## One-time setup

1. Publish and tag SocialKit, then use the same version in this app's Swift
   package dependency. The project is configured for SocialKit `0.1.0`.
2. Enable Pages for `BraveNewDesign/Indie-Dev-Buddy` with **GitHub Actions** as
   the build and deployment source. The included workflow publishes `docs/`.
3. The appcast and app feed URL are configured for the repository's Pages site.
4. Install a Developer ID Application certificate and configure a `notarytool`
   Keychain profile. The release script never stores signing credentials in Git.
5. Resolve Sparkle's package, run its `generate_keys` tool once, and keep the
   private key in the login Keychain. Put only its public key in
   `SPARKLE_PUBLIC_ED_KEY` when building releases. When `generate_appcast`
   first signs an update feed, approve its Keychain access to that private key.

## Prepare a release

Run `scripts/release-direct.sh VERSION BUILD_NUMBER` with these environment
variables set:

- `DEVELOPER_ID_APPLICATION` — the Developer ID Application signing identity.
- `NOTARY_PROFILE` — the profile configured with `xcrun notarytool store-credentials`.
- `SPARKLE_FEED_URL` — the public URL ending in `/appcast.xml`.
- `SPARKLE_PUBLIC_ED_KEY` — the public Sparkle EdDSA key.
- `SPARKLE_DOWNLOAD_BASE_URL` — the Pages URL ending in `/updates/`.
- `SPARKLE_TOOLS_DIR` — optional; the directory containing Sparkle's tools if
  it cannot be found under the script's DerivedData directory.

The script builds and signs the app, notarizes and staples the app and DMG,
creates the Sparkle ZIP, and regenerates `docs/appcast.xml`. Review the feed and
release assets, then commit and push `docs/appcast.xml` and `docs/updates/` to
publish the update feed. Set `PUBLISH_GITHUB_RELEASE=1` to also create a GitHub
Release tagged `vVERSION` and upload the DMG automatically; otherwise create the
release manually after review.

Keep all historical ZIP archives in `docs/updates/`: existing appcast entries
refer to those versioned files. GitHub Pages has a 1 GB published-site limit, so
move update archives to a dedicated release asset host if the archive collection
approaches that limit.

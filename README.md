# Indie Dev Buddy

Indie Dev Buddy is a native macOS workspace for planning and managing indie software projects, content, and social publishing.

## Social account setup

The app supports local Meta token connections for Facebook Pages, Instagram professional accounts, and Threads profiles. The step-by-step setup guide explains required Meta app permissions, Graph API Explorer, account IDs, token types, and development access:

- [Facebook Pages, Instagram, and Threads setup](docs/SOCIAL_CONNECTIONS.md#meta-token-lifetime)
- [Agent pack and command-line tool](docs/README.md)

Meta tokens are stored in the macOS Keychain. Never commit or share access tokens or app secrets. For development, keep the Meta app in Development mode and use app-role or tester accounts; broader access may require Meta App Review.

## Build

Open `Indie Dev Buddy.xcodeproj` in Xcode and build the **Indie Dev Buddy** scheme for macOS.

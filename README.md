# 007 Talk

A tiny, fast Nextcloud Talk client for macOS — text chat only, no calls.

- Menu bar icon with unread count; click it for your 3 most recent conversations
- Plain chat window: conversation list, search, replies, links and files, edits/deletions
- Sign in through the browser (Nextcloud Login Flow); the app password is kept in the Keychain
- macOS notifications following Talk's rules (1:1 always, groups on mention)
- Launch at login, optional Dock icon
- Native Swift/SwiftUI, no dependencies, macOS 13+, Apple Silicon and Intel

## Install
1. Download `007-Talk-x.y.z.zip` from [Releases](../../releases), unzip, move **007 Talk.app** to Applications.
2. The app isn't notarized, so the first launch is blocked: open **System Settings → Privacy & Security** and click **Open Anyway**
   (or run `xattr -dr com.apple.quarantine "/Applications/007 Talk.app"`).
3. Enter your Nextcloud address, approve in the browser, done.

## Build
GitHub Actions builds every push to `main`. Bump `VERSION` to publish a new release.
Locally on a Mac: `bash scripts/bundle.sh` → `build/007 Talk.app`.

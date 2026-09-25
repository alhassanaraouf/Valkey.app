# Valkey.app

macOS menu-bar app for [Valkey](https://valkey.io) — the open-source Redis replacement.

Mimics [Postgres.app](https://postgresapp.com): run several Valkey servers side by side, each on its
own port, version and data directory, with its own live log. Valkey versions are installed from a signed
registry, so new Valkey releases don't need a new app release.

## Repository layout

| Path | What |
|------|------|
| `app/` | macOS app (Xcode project, SwiftUI sources, DMG script) |
| `registry/` | `registry.json` + signature, and tooling to build, package, sign and check Valkey versions |
| `website/` | valkey.app static site |
| `Artwork/` | logo and app icon sources |
| `.github/workflows/` | publish a Valkey version; deploy the website |

## Requirements

- macOS 13+
- Apple Silicon or Intel

## Install

Download `Valkey.app.zip` from Releases, drag to `/Applications`, launch.

## Usage

- **Window** — sidebar lists servers (status, port, version); **+** / **−** add and remove servers,
  **Versions…** installs or removes Valkey versions. The detail pane has **Server Settings…**,
  **Connect…** (opens `valkey-cli` in Terminal), **Show in Finder**, **Start** / **Stop**, and the server's log.
- **New server** — pick any available version; it's downloaded on **Create Server** if not installed yet.
- **Server settings** — name, port and start-automatically can change any time (a running server restarts).
  The version can only move up to a newer installed version; older versions may not read newer data files.
- **Menu bar** — each server with Start/Stop, Connect and Show Data Directory; **Settings…**.
- **Dock** — the app is in the Dock while one of its windows is open and hides to the menu bar when
  they're all closed (it stays in the Dock if the menu-bar icon is turned off).
- **⌘Q** closes the windows and keeps Valkey (and your servers) running in the menu bar. To really quit,
  use **Quit** in the menu-bar menu or the Dock icon's menu. Without the menu-bar icon, ⌘Q quits.
- **Settings** (⌘,) — show in menu bar, open at login, and the terminal used by **Connect…**
  (any installed app that runs `.command` scripts: Terminal, iTerm2, Ghostty, …). Ghostty 1.3+ is
  driven through its AppleScript interface, which skips Ghostty's per-script "Allow" prompt; macOS asks
  once for permission to control Ghostty.
- Removing a server stops it but keeps its data directory. Quitting the app stops all servers gracefully.

Files, all under `~/Library/Application Support/Valkey/`:

- `Versions/<version>/bin/` — installed `valkey-server` / `valkey-cli`
- `var-<port>/` (default per server) — `valkey.conf` (from `app/Valkey/valkey.conf.default`), data files, `valkey.log`

## Version registry

The app reads `https://valkey.app/registry.json` plus `registry.json.sig`, kept in [`registry/`](registry/)
and deployed with the website.

```json
{
  "schemaVersion" : 1,
  "versions" : [
    {
      "version" : "9.1.2",
      "url" : "https://github.com/alhassanaraouf/Valkey.app/releases/download/valkey-9.1.2/valkey-9.1.2-macos-universal.tar.gz",
      "sha256" : "…",
      "size" : 3471939,
      "minimumMacOS" : "13.0",
      "published" : "2026-09-25"
    }
  ]
}
```

- `registry.json.sig` is an Ed25519 signature over the exact bytes of `registry.json`. The app only
  trusts the registry if it verifies against the public key in `app/Valkey/VersionStore.swift`, and only
  installs a download whose size and SHA-256 match its entry. Versions needing a newer macOS are hidden.
- Each package is a `.tar.gz` with `bin/valkey-server`, `bin/valkey-cli` (universal, signed) and Valkey's `COPYING`.
- To test against another registry: `defaults write app.valkey.Valkey registryURL http://127.0.0.1:8000/registry.json`.

### Publishing a Valkey version

Run the **Publish Valkey version** workflow (Actions → Run workflow) with e.g. `9.1.3`. It:

1. builds arm64 + x86_64 from source verified against [valkey-io/valkey-hashes](https://github.com/valkey-io/valkey-hashes)
   (`registry/scripts/package-valkey.sh`),
2. uploads the package to the GitHub release `valkey-<version>`,
3. adds it to `registry/registry.json`, signs it, verifies the signature and commits both files,
4. redeploys the website so the new version is live.

It needs the repository secret `VALKEY_REGISTRY_PRIVATE_KEY` (contents of the private key file).

Locally, the same steps are:

```bash
registry/scripts/package-valkey.sh 9.1.3
swift registry/scripts/registry.swift add registry/registry.json 9.1.3 <release-asset-url> registry/dist/valkey-9.1.3-macos-universal.tar.gz
VALKEY_REGISTRY_PRIVATE_KEY=$(cat ~/.config/valkey-app/registry-signing-key) swift registry/scripts/registry.swift sign registry/registry.json
```

**Signing key.** Generated with `swift registry/scripts/registry.swift keygen <file>`, which writes the private key
to `<file>` (mode 600) and prints the public key for `VersionStore.releaseKey`. Keep the private key out of
the repo; anyone holding it can publish binaries the app will install. If it leaks, generate a new pair,
update `releaseKey`, re-sign the registry and ship an app update.

## App updates

Valkey.app 1.2+ updates itself with [Sparkle](https://sparkle-project.org). It checks the feed
`https://valkey.app/appcast.xml` ([`website/appcast.xml`](website/appcast.xml)) daily, or on demand via
**Check for Updates…** (app menu, menu-bar menu, Settings). **Settings → Updates** turns the daily check on or off.

- When an update is found, Sparkle shows its release notes and asks before downloading (**Install Update**,
  then **Install and Relaunch**); silent auto-install is disabled. A background check never takes focus, so
  keystrokes meant for another app can't accept it; the Dock icon bounces instead.
- The download must carry an Ed25519 signature from the same key as the Valkey registry (`SUPublicEDKey`).
  Sparkle replaces the app in place and relaunches it; servers that were running are stopped gracefully and
  started again.
- To test against a local feed: `defaults write app.valkey.Valkey updateFeedURL http://127.0.0.1:8000/appcast.xml`.

### Releasing the app

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` (always increasing) in `app/Valkey/Info.plist`.
2. Write `app/release-notes/<version>.md` (Markdown, shown in the update window and on the release page).
3. Commit, push, then run the **Release app** workflow with the version. It builds the DMG and zip, publishes
   the `app-v<version>` GitHub release (marked Latest), signs the zip into `website/appcast.xml`
   (`app/scripts/appcast.swift`), commits it, and redeploys the site.

## Website

[`website/`](website/) is the static site for valkey.app (plain HTML, no build step). The **Deploy website**
workflow publishes it to GitHub Pages together with the registry files whenever either changes.
One-time setup: repo Settings → Pages → Source **GitHub Actions**, custom domain `valkey.app`.

Preview locally: `python3 -m http.server -d website` (copy `registry/registry.json` in to see the version list).

## Development

Needs Xcode. Valkey isn't bundled, so app builds are quick.

```bash
open app/Valkey.xcodeproj   # then Run (⌘R)

xcodebuild -project app/Valkey.xcodeproj -scheme Valkey -configuration Debug -derivedDataPath app/build/DerivedData build
app/scripts/create-dmg.sh              # universal Release build → app/build/Valkey.app.zip + Valkey.dmg
registry/scripts/check-registry.sh     # end-to-end check: signing, install, tampered registry, corrupted download
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).

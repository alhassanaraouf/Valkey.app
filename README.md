# Valkey.app

macOS menu-bar app for [Valkey](https://valkey.io) — the open-source Redis replacement.

Mimics [Postgres.app](https://postgresapp.com): run several Valkey servers side by side, each on its
own port, version and data directory, with its own live log. Everything is bundled — nothing else to install.

## Requirements

- macOS 13+
- Apple Silicon or Intel

## Install

Download `Valkey.app.zip` from Releases, drag to `/Applications`, launch.

Bundled versions (plain core, no modules, no TLS, universal binaries): Valkey 8.0, 8.1, 9.0, 9.1.

## Usage

- **Window** — sidebar lists servers (status, port, version); **+** / **−** add and remove servers.
  The detail pane has **Server Settings…**, **Connect…** (opens `valkey-cli` in Terminal), **Show in Finder**,
  **Start** / **Stop**, and the server's log.
- **Menu bar** — each server with Start/Stop, Connect and Show Data Directory; **Open at Login**.
- Server settings: name, port (changing it restarts a running server), start automatically when the app opens.
  Version and data directory are chosen when the server is created.
- Removing a server stops it but keeps its data directory. Quitting the app stops all servers gracefully.

Each server's data directory (default `~/Library/Application Support/Valkey/var-<port>/`) holds its
`valkey.conf` (created from `docs/valkey.conf.default`), data files and `valkey.log`.

## Development

Needs Xcode (command line tools + `make`/`curl`). No Homebrew or system Valkey needed.

```bash
open Valkey.xcodeproj   # then Run (⌘R)
```

The **Embed Valkey** build phase (`buildscripts/embed-valkey.sh`) downloads the pinned
source of each version (SHA-256 verified), builds it for each target arch via `valkey-src/Makefile`,
and embeds `valkey-server` / `valkey-cli` in `Valkey.app/Contents/Versions/<major.minor>/bin`.
The first build takes a few minutes; later builds reuse `valkey-src/build/`.

Command line:

```bash
xcodebuild -project Valkey.xcodeproj -scheme Valkey -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Valkey.app

./scripts/create-dmg.sh   # universal Release build → build/Valkey.app.zip + build/Valkey.dmg
```

To add or bump a version, edit `VERSIONS` and its `SHA256_<version>` line in `valkey-src/Makefile`.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

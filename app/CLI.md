# valkey-app — command-line interface

`valkey-app` lets people and AI agents do everything Valkey.app's UI does, and query everything it shows.
It is the app's own executable (`Valkey.app/Contents/MacOS/Valkey`) run under the name `valkey-app`, or
with a command as its first argument. Homebrew links it with
`binary "#{appdir}/Valkey.app/Contents/MacOS/Valkey", target: "valkey-app"`.

The CLI never edits settings or starts processes itself. It sends each command to the running app over a
local CFMessagePort (`app.valkey.Valkey.cli`), and the app does what the matching UI control does, through
the same `ServerStore` / `VersionStore` methods and the same checks (`ServerStore.problem(with:)`,
`ConfigRules`). If the app isn't running, the CLI starts it hidden. `valkey-app app` reports
`"running": false` without starting it.

## Help

- `valkey-app` or `valkey-app help` lists every command with a one-line summary.
- `valkey-app help <command>`, or `valkey-app <command> --help`, shows the command's usage, arguments, every
  option with a description, and examples, e.g. `valkey-app help create` or `valkey-app user add -h`.
- `valkey-app help --json` prints the whole reference (commands, arguments, options, examples) as JSON, for agents.
- `valkey-app --version` prints the app's version.
- Mistakes get a usage line and a hint, e.g. `Unknown option --prot. Did you mean --port?`.

Commands, options and help text are defined once, in `Valkey/CLICommands.swift`. Parsing and every help
view come from that list, so adding a command or option there documents it. Source: `Valkey/CLI.swift`
(client), `Valkey/CLICommands.swift` (commands, parsing, help) and `Valkey/CLIServer.swift` (app side).
Tests: `scripts/test-cli.sh`; they check that every command and option is documented and that every example parses.

## Conventions

- `<server>` is a name, port or id. A name shared by several servers is an error (exit 3); use the port or id.
- `--json` prints the command's result as JSON on stdout. Errors print `{"error": "…"}` with a non-zero exit code.
  Keys are stable and sorted. Optional keys are omitted when unset (treat a missing key as `null`).
- Passwords are never printed unless you pass `--show-secrets`. `url` masks the password as `****` without
  it. `cli` passes the password to valkey-cli in `REDISCLI_AUTH`, never on the command line.
- `--password -` reads the password from stdin. `--password ""` removes it.
- Exit codes: 0 ok, 1 failed, 2 usage, 3 not found / ambiguous, 4 Valkey.app unreachable.
- Long operations (downloads, `stats`) run as jobs in the app. The CLI waits for them to finish.
- `start` / `restart` wait until the port accepts connections, and `stop` waits until the process has
  exited. Each fails with the server's error.

## JSON shapes

**Server** (`list`, `status`, `show`, `create`, `set`, `start`, `stop`, `restart`, `delete`, `user …`):
`id`, `name`, `version`, `port`, `state` (`running` | `stopping` | `stopped` | `failed`), `pid`, `failure`,
`startAutomatically`, `autoRestart`, `persistence`, `maxMemory` (e.g. `"256mb"`, absent = no limit),
`evictionPolicy`, `hasPassword`, `password` (only with `--show-secrets`), `users`
(`[{name, readOnly, password?}]`), `modules` (`[{name, title, status: installed|will-download|unavailable,
version?}]`), `dataDirectory`, `configFile`, `logFile`.

**Stats** (`stats`): `memory` (human), `memoryBytes`, `ops` (per second), `clients`, `keys`, `hitRate` (percent).

**Version** (`versions …`): `version`, `installed`, `available`, `published`, `size`, `usedBy` (server names),
`installing` (0–1 while downloading).

**Module build** (`modules …`): `id`, `name`, `title`, `summary`, `version`, `valkey` (supported minor lines),
`installed`, `size`, `usedBy`, `installing`.

**App** (`app …`): `running`, `version`, `build`, `pid`, `appPath`, `dataRoot`, `menuBar`, `openAtLogin`,
`autoUpdate`, `canCheckForUpdates`, `terminal` (bundle id), `terminals` (`[{id, name}]`), `registryURL`,
`registryError`, `valkeyCLILink`, `valkeyCLIPathLine`.

Other results: `url` → `{url}`, `logs` → `{logFile, lines}` (`-f --json` prints one JSON string per line),
and actions without data → `{ok: true}`.

## UI → CLI parity checklist

Keep this list complete: every UI control or displayed value maps to a command, or is listed as excluded
with a reason (see AGENTS.md).

### Main window: sidebar (ContentView)
| UI | CLI |
|---|---|
| Server list: name, status icon, port, version | `list` |
| **+** Add server / **Create Server…** (empty state) | `create` |
| **−** Remove server (confirmation alert; data directory kept) | `delete <server>` (prompts on a TTY, or `--yes`) |
| **Versions…** | `versions`, `modules` (see below) |

### Main window: server detail (ServerDetailView)
| UI | CLI |
|---|---|
| Name, Running / Stopping… / Not running, Modules line, error message | `show <server>` (`state`, `modules`, `failure`) |
| **Server Settings…** | `show <server>`, `set <server> …` |
| **Connect…** (valkey-cli in the chosen terminal) | `connect <server>`; `cli <server> [args]` runs it in the current shell |
| **Copy URL** (default user, or a menu per ACL user) | `url <server> [--user NAME] [--show-secrets]` |
| **Files › Edit valkey.conf** | `open <server> config`; path is `configFile` in `show` |
| **Files › Show in Finder** | `open <server> data`; path is `dataDirectory` in `show` |
| **Start** / **Stop** / **Restart** | `start` / `stop` / `restart <server>` |
| Stats tiles: memory, ops/s, clients, keys, hit rate | `stats <server>` |
| Log view, live | `logs <server> [-n N]`, `logs <server> -f` |
| Log **Filter** field | `logs <server> --filter TEXT` |
| **Open Log File** | `open <server> log`; path is `logFile` in `show` |

### Server Settings / New Server sheet (ServerSettingsView)
| UI | CLI |
|---|---|
| Name | `--name` (or `create <name>`) |
| Version (new: any available, downloaded on Create; existing: only an installed, not-older version) | `--version V`, same rules |
| Port | `--port N` |
| Data Directory (Choose… for a new server) | `create --data-dir PATH`; `dataDirectory` in `show` |
| Start automatically when Valkey.app opens | `--auto-start on|off` |
| Restart automatically if it crashes | `--auto-restart on|off` |
| Password | `--password PW|-|""`; `hasPassword` / `--show-secrets` |
| Save data to disk | `--persistence on|off` |
| Max Memory | `--max-memory SIZE|none` |
| When Full | `--eviction-policy POLICY` |
| Users: Add User, name, password, Full access / Read only, remove | `user add`, `user set [--rename] [--password] [--read-only]`, `user remove`; `users` in `show` |
| Modules list with status (Installed / Downloads … when you save / Not available) | `modules` in `show` (`status`, `version`) |
| Module remove (−) | `set <server> --disable-module NAME` (or `--modules a,b|none`) |
| **Add Module…** | `set <server> --enable-module NAME` |
| Validation messages (port in use, bad size, users, module not available, …) | same messages as errors (exit 1) |
| Download progress on Save / Create | the CLI waits; `installing` in `versions` / `modules` |
| "Loading available versions…" / registry error + **Retry** | `versions refresh`; `registryError` in `app` |
| Warnings (upgrade can't be undone; data may need a removed module) | excluded: the CLI applies the change you asked for; the rules that block invalid changes are the same as the UI's |

### Add Module sheet (ModulePickerView)
| UI | CLI |
|---|---|
| Catalog with title, summary, status for the server's version | `modules --valkey <version>` |
| Search field | excluded: `modules --json` returns the full catalog to filter (e.g. with `jq`) |
| **Add** | `set <server> --enable-module NAME` |

### Versions sheet (VersionsView)
| UI | CLI |
|---|---|
| Valkey list: installed, used by, released, size, progress | `versions` |
| Modules list: version, Valkey lines, installed, used by, size, progress | `modules` |
| **Refresh** | `versions refresh` |
| **Install** / **Remove** (Valkey) | `versions install V` / `versions remove V` (refused while in use) |
| **Install** / **Remove** (module build) | `modules install ID` / `modules remove ID` (refused while in use) |
| Error message | the command's error |

### Settings window (SettingsView)
| UI | CLI |
|---|---|
| Show in menu bar | `app set --menu-bar on|off` |
| Open at login | `app set --open-at-login on|off` |
| Terminal (used by Connect…) | `app set --terminal BUNDLE-ID`; choices in `terminals` |
| Command Line: status, **Install valkey-cli** / **Relink to Newest** | `valkeyCLILink` in `app`; `app link-cli` |
| PATH line + **Copy** | `valkeyCLIPathLine` in `app` |
| Check for updates automatically | `app set --auto-update on|off` |
| Valkey.app version | `version` / `build` in `app` |
| **Check for Updates…** | `app check-updates` |

### Menu-bar menu (StatusMenu) and app menu
| UI | CLI |
|---|---|
| Each server: Start / Stop, Connect…, Copy URL, Show Data Directory | `start`/`stop`, `connect`, `url`, `open <server> data` |
| "No servers" | `list` (empty) |
| **Open Valkey…** | `app open` |
| **Settings…** | `app` / `app set` (opening the Settings window itself is excluded: every setting is in `app`) |
| **Check for Updates…** | `app check-updates` (Sparkle's interactive window opens in the app) |
| **Quit Valkey.app** / **Quit Completely** | `app quit` (stops servers gracefully, waits for exit) |
| **Send Feedback…** / **Report a Bug…** | excluded: they open a pre-filled email for a person to write and send. The diagnostics they include are in `app`, `list`, `show` and `logs` |

### Not actions (excluded)
- ⌘Q closing windows to the menu bar, Dock / menu-bar presence, window layout: window management only.
- Crash notifications: the same information is `state` / `failure` in `show`.

# Agent instructions

## CLI parity

The CLI (`valkey-app`) must stay at full parity with the UI. Any feature, setting or data added or changed in
the app must be added to the CLI in the same change, with `--json` output and tests, so agents can do and query
everything. Update the UI-to-CLI checklist/docs when you do.

- Code: `app/Valkey/CLICommands.swift` (every command, option, help text and example; parsing), `app/Valkey/CLI.swift`
  (client, output) and `app/Valkey/CLIServer.swift` (app side). Put rules the UI and CLI share in the stores or
  `app/Valkey/ConfigRules.swift`, not in a view.
- Every command needs a summary, a description for each argument and option, and at least one example.
  `help <command>` is generated from these.
- Docs and the UI → CLI checklist: `app/CLI.md`.
- Tests: `app/scripts/test-cli.sh` (runs in the App checks workflow).

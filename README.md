# Claude Swap

A DankMaterialShell bar widget for people who use **more than one Claude Code account**. It shows each account's usage, switches accounts with one click, and can switch on its own when the active account runs out of quota. Account handling is done by [claude-swap](https://github.com/realiti4/claude-swap) (`cswap`).

## Features

- **Bar:** 5-hour and weekly usage rings for the active account, plus an icon showing whether auto switch is on.
- **Popout:**
  - one card per account, with email, plan, and 5-hour/weekly usage bars showing the time until reset;
  - **click an account** to make it active;
  - **⚡** switches to the account with the most quota left;
  - **👤+** adds an account: opens a terminal that runs `claude auth login`, then `cswap add`;
  - **auto switch** on/off, with a threshold of 80%, 90%, 95% or "at limit" (99.9%).

Auto switch runs `cswap auto` as a process owned by the shell, so no systemd unit is needed. A `flock` lock keeps a single copy running even with several monitors. On Linux, Claude Code re-reads its credentials file, so open sessions move to the new account on their next message.

## Requirements

- DankMaterialShell 2.1.0 or newer
- [claude-swap](https://github.com/realiti4/claude-swap): `uv tool install claude-swap`
- `flock` (util-linux)
- A terminal for the add-account flow. The default is `alacritty -e`; change it in the plugin settings.

## Installation

```sh
git clone https://github.com/hfb0/dms-claude-swap ~/.config/DankMaterialShell/plugins/claudeSwap
dms ipc call plugin-scan rescan claudeSwap
dms ipc call plugins enable claudeSwap
```

Then add the **Claude Swap** widget to your bar under Settings → Plugins.

### Adding accounts

Use the 👤+ button in the popout, or from a terminal:

```sh
cswap add            # saves the account you are signed in to
# in Claude Code: /login with the other account (do NOT /logout)
cswap add
```

## Updating

```sh
git -C ~/.config/DankMaterialShell/plugins/claudeSwap pull
dms restart
```

DMS caches the plugin directory, so new files from an update only load after a restart.

## Development

Pure logic lives in `ClaudeSwapLogic.qml` (plain functions, no bindings) so it can run under node:

```sh
node --test tests/*.test.js
```

The tests cover JSON parsing, countdown formatting, the shell wrappers (against a fake `cswap`, including the auto-switch lock), the manifest, and translation coverage.

## Translations

The UI is in English, with a Brazilian Portuguese translation in `translations/pt_BR.json`.

## Disclaimer

Rotating accounts to get around usage limits may go against Anthropic's terms. Use at your own risk.

## Credits

- The bar layout, usage rings and popout are inspired by [DankClaudeUsage](https://github.com/bogdan-velicu/DankClaudeUsage) by Bogdan Velicu. `UsageRing.qml` is adapted from it (MIT).
- Account switching and usage data come from [claude-swap](https://github.com/realiti4/claude-swap) by Onur Cetinkol.

## License

MIT

# Luci Core for Linux

Luci Core records what is on each screen of a Linux machine, turns it into searchable text on the machine itself, and lets AI agents ask what is on the screen now or when something was seen. It is the headless version of [Luci](https://luci.memories.ai): no UI, just a local service with an MCP server and the `luci` command line.

This repository holds the installer and the release downloads. The source code is in a private repository for now.

## Requirements

- Linux on x86_64. arm64 has no release yet.
- An X11 display or Xvfb. Wayland sessions are not captured.
- `curl` and `tar`. The installer fetches Node 22 if the machine has none, and installs the runtime libraries it can (with `sudo` or as root).

## Install

```
curl -fsSL https://raw.githubusercontent.com/Memories-ai-labs/luci-core-releases/main/install.sh | sh
```

The installer downloads the latest release from this repository, checks it against `SHA256SUMS`, starts Luci, and prints the snippet to register it with your agent. Running it again upgrades or repairs.

Options go after `sh -s --`, for example `... | sh -s -- --data-dir /workspace/.luci`:

| Option | Use it for |
|---|---|
| `--data-dir <dir>` | Keep data on a persistent disk; `~/.luci` becomes a link to `<dir>` (cloud desktops: `/workspace/.luci`) |
| `--ocr-lang zh` | Add the Chinese text recognition pack (English is included) |
| `--no-systemd` | Run as a background process instead of a systemd user service |
| `--linger` | Keep running after you log out |
| `--no-start` | Install only, do not start |
| `--version <v>` | Install a specific release, e.g. `0.1.0` |
| `--from-tarball <file>` | Install from a file you already downloaded |
| `--dry-run` | Print the plan and change nothing |
| `--uninstall [--purge]` | Remove Luci; `--purge` also deletes the recorded data in `~/.luci` |

## Connect your agent

The installer prints these with the real paths filled in. Luci listens on `127.0.0.1:8765`; `luci mcp` is a stdio bridge to it.

### Grok Bot

Install with `--data-dir /workspace/.luci`:

```
curl -fsSL https://raw.githubusercontent.com/Memories-ai-labs/luci-core-releases/main/install.sh | sh -s -- --data-dir /workspace/.luci
```

Then register a stdio MCP server:

```json
{"command": "/home/<user>/.luci/bin/luci", "args": ["mcp"], "env": {"LUCI_CLIENT": "grokbot:<bot-name>"}}
```

`LUCI_CLIENT` labels the bot's calls (letters, digits, `_ : -`, up to 64 characters). Luci records every screen on the machine; `screen_now` without a `display_id` reads the screen in use, the one whose foreground window changed last. To pin one screen, add `"LUCI_DISPLAY": ":5"`: tool calls that don't name a screen then read and search only that one. Pin it only when the bot always works on the same screen: on Grok Bot a bot can land on a different screen each session.

### Muse

Muse uses the CLI. Install, then give the bot the Luci skill:

```
npx skills add Memories-ai-labs/Luci-skills
```

The bot runs `luci now` and `luci search "..." --tr 24h`. Muse Code can also register the MCP server as above.

Agents often run each command in a fresh shell, where `~/.local/bin` may not be on `PATH`. Then call the CLI by its full path, `~/.luci/bin/luci`; the installer prints whichever one works.

### OpenClaw

Install, then either use the `luci` CLI or add the stdio command above to OpenClaw's MCP configuration (field names depend on your OpenClaw version).

### Let the bot install it

Paste this to a bot on its cloud desktop:

```
Install Luci Core on this machine and connect it to yourself. Show me the full output of each step. If a step fails, stop and show me; don't work around it.

1. Run: curl -fsSL https://raw.githubusercontent.com/Memories-ai-labs/luci-core-releases/main/install.sh | sh -s -- --data-dir /workspace/.luci
   If /workspace doesn't exist, leave out everything after "| sh".
2. Register the MCP server exactly as the installer's "As one JSON block" line says. Put your own name after "grokbot:".
3. Check it: open a terminal or text window on your screen that shows the line LUCI TEST 4821. Then run the "now" command the installer printed, and confirm the output contains LUCI TEST 4821.

Always use the luci path the installer printed. Luci only sees what is drawn on your screen, so open browsers and apps in a window, not headless.
```

## Everyday commands

```
luci now                          # the screen in use, right now
luci now --display :1 --json      # one screen, as JSON
luci search "invoice" --tr 24h    # search the last 24 hours
luci-core status                  # is it running, which screens
luci --help
```

Every X display is its own screen. One Xvfb per bot keeps their histories apart:

```
Xvfb :1 -screen 0 1280x800x24 -nolisten tcp &
```

## What Luci can see

Luci reads what is drawn on an X screen, nothing else:

- Browsers and apps must run in a window on a screen. Headless browsers (headless Chrome, Playwright with `headless: true`) and plain terminal output never reach a screen, so Luci can't see them.
- An idle desktop with no open window reads as empty. That is not an error.
- Text comes from the app's accessibility tree when the desktop session provides one, otherwise from recognizing the pixels. English is included; add `--ocr-lang zh` for Chinese.
- App names are what the window reports. A wrapped browser can show up as its wrapper's name (for example `box-chrome`), so check `luci usage` before filtering with `--app`.

## Verify a download by hand

Each release has a `SHA256SUMS` file covering its assets:

```
base=https://github.com/Memories-ai-labs/luci-core-releases/releases/latest/download
curl -fsSLO "$base/luci-core-linux-x64.tar.gz"
curl -fsSLO "$base/SHA256SUMS"
sha256sum -c SHA256SUMS --ignore-missing
curl -fsSLO https://raw.githubusercontent.com/Memories-ai-labs/luci-core-releases/main/install.sh
sh install.sh --from-tarball luci-core-linux-x64.tar.gz
```

With `--from-tarball`, the installer also checks the tarball against a `SHA256SUMS` in the same directory. Add `ocr-zh-v1.tar.gz` to the same directory for `--ocr-lang zh`.

## Uninstall

```
curl -fsSL https://raw.githubusercontent.com/Memories-ai-labs/luci-core-releases/main/install.sh | sh -s -- --uninstall
```

This keeps the recorded data in `~/.luci`. Add `--purge` to delete it too (`--uninstall --purge`). If `~/.luci` is a link made by `--data-dir`, `--purge` removes the link and leaves the data directory for you to delete.

## Privacy

Everything stays on the machine. The server listens on loopback only, with one token per machine, and keeps 7 days of history by default.

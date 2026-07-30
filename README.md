# TokPulse

TokPulse is a native macOS menu bar monitor for effective AI Agent output throughput. It reads local Codex and Qoder session logs and groups root agents and subagents into sessions.

The menu bar shows:

- `Avg`: the arithmetic mean of all currently available Agent rates.
- `Σ`: the arithmetic sum of those same Agent rates.

The expanded dashboard also shows:

- `Active Time`: today's union of model-active intervals. Concurrent Agents count only once.
- `Today Rate`: all output tokens from responses completed today divided by `Active Time`.

The menu expands each session into its root agent and subagents. Session and global `Σ` values are additive, so the visible Agent rates add up to the menu-bar total before display rounding.

## How TPS is calculated

For each Agent, TokPulse selects its latest completed response that ended within the last 60 seconds:

```text
Agent TPS = output tokens / inferred model-active seconds
Σ         = sum of all qualifying Agent rates
Avg       = arithmetic mean of all qualifying Agent rates
```

Tool execution, approval/user waits, idle time, and time between prompts are excluded when the event pairs are complete. A value is held until a newer completed response arrives or its 60-second TTL expires; it is not prorated at the cutoff. Stale subagents disappear, while a root Agent can remain as `—` for up to three minutes without participating in `Avg` or `Σ`.

Token sources differ by provider:

- **Codex:** uses reported `last_token_usage.output_tokens`. Model-active time is inferred from input-ready, model-output, tool-call, tool-output, and turn lifecycle timestamps.
- **Qoder CLI / Quest:** neither format reports token usage, so visible text, plaintext reasoning, and tool arguments use `ceil(ASCII characters / 4) + non-ASCII characters`. Opaque/redacted reasoning is excluded. Tokens and model-active timing are therefore labelled estimated/inferred.

This is a last-observed response rate, not pure decode TPS or the exact number of tokens arriving during the current second.

`Active Time` and `Today Rate` use the Mac's current calendar day and refresh once per minute. Completed intervals are clipped at local midnight and merged before their duration is summed. A currently answering Agent contributes from the start of its current model-active interval through the refresh time; tool waits and idle time remain excluded.

## Supported AI clients

| Client | Sessions | Local read-only source |
| --- | --- | --- |
| Codex | Root Agents and subagents | `~/.codex/sessions`, `~/.codex/archived_sessions` |
| Qoder CLI | Root Agents and subagents | `~/.qoder/projects` |
| Qoder Quest | Quest sessions | `~/Library/Application Support/Qoder/SharedClientCache/cli/projects` |

## Privacy

Session logs are read locally and never modified. TokPulse parses only the fields needed for metrics and does not retain content; prompt text, reasoning text, tool arguments, and tool output are never stored, displayed, or logged. TokPulse makes no network requests.

## CLI

The app bundle includes the same telemetry CLI that feeds the menu-bar UI. It can emit one complete JSON snapshot or a continuous JSON Lines stream:

```sh
/Applications/TokPulse.app/Contents/Helpers/tokpulse-cli snapshot --json
/Applications/TokPulse.app/Contents/Helpers/tokpulse-cli stream --json-lines
```

Run `/Applications/TokPulse.app/Contents/Helpers/tokpulse-cli --help` for the optional pretty-printing and stream-interval flags. The JSON schema includes the dashboard metrics, daily metrics, answering-Agent count, and diagnostic count.

## Install

TokPulse targets macOS 13 or newer and has no third-party dependencies.

Build the app bundle, install it in `/Applications`, and launch it:

```sh
./scripts/build-app.sh
ditto .build/TokPulse.app /Applications/TokPulse.app
open -a TokPulse
```

After installation, TokPulse can also be launched from Spotlight by searching for `TokPulse`.

For a standard SwiftPM build, install a matching Xcode or Command Line Tools toolchain, then run:

```sh
swift test
swift build -c release
```

If the installed Swift compiler and SDK patch versions do not match, use `./scripts/test-local.sh` and `./scripts/build-app.sh`; the direct-build app targets the current host OS.

## Design note

The compact label and stacked menu-card layout are informed by the MIT-licensed [CodexBar](https://github.com/steipete/CodexBar). TokPulse has an independent implementation and does not reuse CodexBar branding or assets.

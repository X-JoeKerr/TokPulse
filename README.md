# TokPulse

TokPulse is a native macOS menu bar monitor for effective Codex output throughput. It reads local Codex rollout JSONL and groups root agents and subagents into sessions. Each Agent contributes its latest completed model-call rate while that sample is at most 60 seconds old.

The menu bar shows:

- `Avg`: the arithmetic mean of all currently available Agent rates.
- `Σ`: the arithmetic sum of those same Agent rates.

The popover expands each root session into its root agent and subagents, with each Agent's last rate, latest output-token count, inferred model-call duration, and model metadata. Session and global `Σ` values are additive, so the visible Agent values add up to the menu-bar total before display rounding.

## Metric boundary

TokPulse measures **model-effective output TPS**, not pure decode TPS:

- Counts come from `last_token_usage.output_tokens`, including reasoning, visible output, tool-call arguments, and other generated structure.
- Model-active timing is inferred from input-ready, model output, tool-call, tool-output, and turn lifecycle timestamps.
- Tool execution, approval/user waits, idle time, and time between prompts are excluded when the event pairs are complete.
- A response is committed only after its token usage arrives. Its full output-token count is divided by its full inferred model-active duration.
- For each Agent, only the latest completed sample whose end time is within the last 60 seconds qualifies. The value stays unchanged until a newer sample arrives or the 60-second TTL expires; it is not prorated at the cutoff.
- A Subagent disappears when its sample expires. A stale Main/Root Agent can remain as `—` while its session file is still within the three-minute inventory, but it does not participate in `Avg` or `Σ`.
- This is a last-observed segment rate, not the exact number of tokens arriving during the current second. Codex local logs do not expose per-token timestamps.

## Privacy

The app reads `~/.codex/sessions` and `~/.codex/archived_sessions` locally. It extracts structural metadata, timestamps, IDs, and token counts. Prompt text, reasoning text, tool arguments, and tool output are never stored, displayed, or logged. TokPulse makes no network requests.

## Build and run

TokPulse targets macOS 13 or newer and has no third-party dependencies.

With a matching Xcode or Command Line Tools installation:

```sh
swift test
swift build -c release
```

On the current development machine, the installed Swift compiler and SDK patch versions do not match for SwiftPM manifest compilation. The checked-in local scripts compile against the host SDK directly while leaving the standard package intact:

```sh
./scripts/test-local.sh
./scripts/build-app.sh
open .build/TokPulse.app
```

The direct-build app targets the current host OS. Use a matching full Xcode toolchain when producing a macOS 13-compatible distribution build.

## Design note

The compact label and stacked menu-card layout are informed by the MIT-licensed [CodexBar](https://github.com/steipete/CodexBar). TokPulse has an independent implementation and does not reuse CodexBar branding or assets.

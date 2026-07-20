# TokPulse

TokPulse is a native macOS menu bar monitor for effective Codex output throughput. It reads local Codex rollout JSONL, groups root agents and subagents into sessions, and reports activity from the most recent ten minutes.

The menu bar shows:

- `Avg`: generated output tokens divided by summed per-agent model-active seconds.
- `Σ`: generated output tokens divided by the wall-clock union of all model-active intervals, preserving concurrent subagent throughput.

The popover expands each root session into its root agent and subagents, with average TPS, output tokens, inferred active time, and model metadata.

## Metric boundary

TokPulse measures **model-effective output TPS**, not pure decode TPS:

- Counts come from `last_token_usage.output_tokens`, including reasoning, visible output, tool-call arguments, and other generated structure.
- Model-active timing is inferred from input-ready, model output, tool-call, tool-output, and turn lifecycle timestamps.
- Tool execution, approval/user waits, idle time, and time between prompts are excluded when the event pairs are complete.
- A response is committed only after its token usage arrives. An in-progress response does not enter the denominator as zero-token time.
- A segment crossing the ten-minute boundary is prorated and marked estimated because Codex does not expose per-token timestamps in local rollout logs.

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

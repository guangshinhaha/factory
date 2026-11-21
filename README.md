# factory

Orca-native, daemon-less software factory: turns `ready` GitHub issues into reviewed, merged PRs.
See CLAUDE.md for the layout and the plan issue (#11).

## Config

Set in the target repo's CLAUDE.md, on its default branch. `sf-init` adds `factory-concurrency` and `factory-sensitive`.

- `shinstack-mode: auto|supervised|manual`: how far the factory goes on its own (merge needs `auto`).
- `factory-concurrency: N`: live Runs for this repo (default 2).
- `factory-release-path: #N`: while issue N is open, only the ready issues on its list lines (`- #12`,
  `1. #12`, `- [ ] #12`; prose mentions don't count) start, in list order. N closed: no path, all ready
  issues start. Not exactly one `#N` line, or an N that doesn't exist: `sf-state` errors and nothing starts.
- `factory-sensitive: true|false`: with `true`, review stays on Claude (`claude/opus`) and ignores any
  `factory-model.review` line.
- `factory-model.<station>: <agent>/<model>`: overrides a station's worker. Stations: `intake`, `plan`,
  `build`, `review`, `verify`, `debrief`. Agents: `claude`, `codex`. Not added by `sf-init`. Defaults
  (in `bin/sf-act`): intake `claude/sonnet`, plan `claude/opus`, build `claude/sonnet`, review
  `codex/codex-auto-review`, verify `claude/opus`, debrief `claude/haiku`. A malformed or repeated line,
  or an unknown station or agent, stops the issue naming the line.

Host-wide, in the environment: `FACTORY_MAX_RUNS` caps live Runs across all repos (default 4).

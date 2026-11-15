# factory

Orca-native, daemon-less software factory. Turns `ready` GitHub issues into reviewed, merged PRs.
GitHub holds the backlog and state, Orca runs the workers, and this repo is a Claude Code plugin
(skills + POSIX gate scripts) that holds the policy. Replaces guangshinhaha/shinfactory (Go loop).
Plan: docs/plan.md.

## Commands

- `scripts/check`: shellcheck on every shell script, then all tests. Runs in pre-push and CI.
- `test/run [file...]`: tests only (default `test/*_test.sh`).

Before a PR: `scripts/check` passes.

## Layout

- `.claude-plugin/`: plugin manifest, plus a one-plugin marketplace so `claude plugin install` works from a local path.
- `skills/`: stations (one dir per skill). `bin/`: gate scripts (`sf-*`); Claude Code puts plugin `bin/` on PATH, so only shipped commands go here.
- `scripts/`: dev-only scripts. `test/`: tests, `test/fakes/` (fake `gh`/`orca`), `test/fixtures/<set>/<tool>/`.
- Tests: write `test_*` functions in `test/<name>_test.sh`; `use_fixtures <set>` picks fixtures, `assert_called` checks the call log.
  The fake prints a fixture's key with `sh test/fakes/fake-cli --key <args...>`. A test that finds no fake hits the guard and fails.

## Gates

Hooks and CI come from gantry (`lefthook.yml`, `.github/workflows/ci.yml`).
A task is done only when the pre-push checks pass. Never use `--no-verify`.

## Coding

- Cross-platform (macOS/Windows/Linux): POSIX sh only, no bash 4+ features.
- State lives only in GitHub and Orca. Never add a local state file.
- Tests never call real `gh` or `orca`; put fakes on PATH.
- Error messages describe the failure state ("run not found"), not the expectation.
- No backward compatibility with shinfactory's files or config.

## Working style

If the shinstack plugin (github.com/guangshinhaha/shinstack) is installed, follow `shinstack:craft`, which its session hook loads. If it isn't installed, ignore this section.

## shinstack
shinstack-mode: auto

## Review rules

- Skills, gate scripts and automation setup are risk:high (`.github/gantry-risky-paths`).

## Knowledge

- Plan: docs/plan.md
- Decisions: docs/decisions/
- Solved problems and gotchas: docs/solutions/

# factory

Daemon-less software factory on T3 Code. Turns `ready` GitHub issues into reviewed, merged PRs.
GitHub holds the backlog and state, T3 Code runs the workers, and this repo is a Claude Code plugin
(skills + POSIX gate scripts) that holds the policy. Replaces guangshinhaha/shinfactory (Go loop).
Plan: tracking issue #11 (no plan file; plans live in GitHub issues).

## Commands

- `scripts/check`: shellcheck on every shell script, then all tests. Runs in pre-push and CI.
- `test/run [file...]`: tests only (default `test/*_test.sh`).

Before a PR: `scripts/check` passes.

## Layout

- `.claude-plugin/`: plugin manifest, plus a one-plugin marketplace so `claude plugin install` works from a local path.
- `skills/`: stations (one dir per skill). `bin/`: gate scripts (`sf-*`); Claude Code puts plugin `bin/` on PATH, so only shipped commands go here.
- `scripts/`: dev-only scripts. `test/`: tests, `test/fakes/` (fake `gh` and gantry gates; `orch-fake.sh` stands in for the `lib/orch.sh` seam), `test/fixtures/<set>/<tool>/`.
- Tests: write `test_*` functions in `test/<name>_test.sh`; `use_fixtures <set>` picks fixtures, `assert_called` checks the call log.
  The fake prints a fixture's key with `sh test/fakes/fake-cli --key <args...>`. A test that finds no fake hits the guard and fails.

## Gates

Hooks and CI come from gantry (`lefthook.yml`, `.github/workflows/ci.yml`).
A task is done only when the pre-push checks pass. Never use `--no-verify`.
Merge only with `gh pr merge --squash --match-head-commit <sha>`. If gh refuses, stop and report the refusal: the REST merge endpoint silently uses the admin bypass (PR #16).

## Releases

- Claude Code updates the installed plugin only when `version` in `.claude-plugin/plugin.json` changes, so a merge that changes `bin/`, `skills/` or `lib/` does not reach other repos until the version is bumped.
- Bump `version` (semver: minor for a new capability, patch for a fix) in the PR that finishes a milestone, or in a `chore: release x.y.z` PR right after it. Do it without being asked.
- The `factory` marketplace has `autoUpdate` on in `~/.claude/settings.json`: a bumped version on `main` is picked up unattended. Never bump on a branch with an unverified gate script.

## Coding

- Cross-platform (macOS/Windows/Linux): POSIX sh only, no bash 4+ features.
- State lives only in GitHub and the T3 thread list. Never add a local state file.
- Plans and task tracking live in GitHub issues. Never add a plan or TODO .md file.
- Tests never call real `gh` or T3; put fakes on PATH.
- Error messages describe the failure state ("run not found"), not the expectation.
- No backward compatibility with shinfactory's files or config.

## Working style

If the shinstack plugin (github.com/guangshinhaha/shinstack) is installed, follow `shinstack:router`, which its session hook loads. If it isn't installed, ignore this section.

## shinstack
shinstack-mode: auto

## Review rules

- Skills, gate scripts and automation setup are risk:high (`.github/gantry-risky-paths`).

## Knowledge

- Plan: issue #11
- Decisions: docs/decisions/
- Solved problems and gotchas: docs/solutions/

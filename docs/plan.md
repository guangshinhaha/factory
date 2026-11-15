# factory: plan v2

Orca-native, daemon-less replacement for guangshinhaha/shinfactory (a Go fork of poteto's noodle).
v1 drafted 2026-11-15; v2 folds in an advisor review the same day.

## Goal
Turn `ready` GitHub issues into reviewed, merged PRs unattended. GitHub is the backlog and the state,
Orca is the runtime, and this repo's plugin (skills + gate scripts) is the policy. Follow shinstack
principles, not noodle's "everything is a file" design.

## Why rebuild
- About half of shinfactory's 30 newest open issues are the loop's own state drifting from Orca/GitHub,
  or loop-process lifecycle: #205 #209 #210 #216 #223 #224 #225 #228 #229 #231 #234 #244 #247 #248 #249 #250.
- 36k LOC Go + 44k LOC tests, mostly reducer/projection/snapshot/monitor/dispatcher.
- Orca already has workers, task DAGs with deps, worker_done, ask/reply, scheduled automations
  (cron, `--precheck`, fresh or reused session), worktrees, and issue<->workspace links
  (`orca reference add/find`).

## Shape: three parts, no daemon
| Part | What | Owns |
|---|---|---|
| Conveyor | Orca: one automation per repo, one Run per issue, a task DAG per Run, workers | who runs, liveness |
| Stations | `factory` plugin skills: foreman, intake, plan, build, review, verify, debrief, triage, init | judgment |
| Gates | POSIX sh scripts, no judgment: `sf-state`, `sf-tick`, `sf-gate-evidence`, `sf-verdict-check`, `sf-ship`, `sf-stop` | evidence, merge safety, stop |

Gate scripts that apply to any repo (evidence, verdict-check) live in gantry per the ownership rule
("a check with no judgment goes in gantry"). Factory-only scripts (state, tick, ship, stop) live here.

State lives only in GitHub and Orca. Where a fact has no natural home, it goes in a GitHub marker
comment on the PR or issue (`<!-- factory:{"kind":"attempt",...} -->`), never a local file.

## Flow of one issue
1. **Automation.** One per repo, cron every 5 min, provider claude, **fresh session per fire**,
   prompt `/factory:foreman`. `--precheck sf-precheck` exits non-zero when there is nothing to do,
   so most fires start no agent.
2. **`sf-tick` (foreman as a script, Shin 2026-11-15).** Runs as the automation's precheck, so no agent starts and scheduling costs no tokens. Takes a `mkdir` lock (two overlapping fires: the second exits). Runs `sf-state`, which
   prints the *action list* as JSON: `start #N`, `advance run R`, `stop #N reason`, `ship PR`, `hold #N`.
   `sf-tick` carries out the list itself and exits non-zero. Judgment lives only in the stations.
   `sf-state` rules:
   - list open issues once and filter with jq; never the GitHub search API (26h block, shinfactory#175);
   - join issue -> Runs with `orca reference find`; join issue -> PR by branch, not by memory;
   - a dead Run with a hold marker past its reset time = restart that task (not an attempt);
   - a dead Run with no hold marker and no `needs-shin` = **owes a stop**, never startable (unsent-stops lesson);
   - attempts = attempt markers since the last `ready` label event (timeline API), so re-readying resets the count;
   - at most `concurrency` live Runs.
3. **intake.** No observable Done when -> stop. An undeclared `Depends on` -> hold, not fail (#243).
   Tier from `risk:` label (unclear -> higher). work_type from bug/enhancement/refactor. Complex with
   no plan -> plan task first.
4. **Run DAG** (each task is an Orca worker; briefs say subagents are allowed, because Orca's preamble forbids them otherwise):
   - **plan** (only when needed, Opus): `/plan` + adversarial-review, no code; links plan from the issue.
   - **build** (Claude Sonnet, `SHINFACTORY_ROLE=build`): shinstack feature / bug-fix / refactoring
     playbook. Branch from freshly fetched origin default using the repo's branch convention (#227);
     delete a stale remote branch from an earlier closed PR (#186). Commits only.
   - **`sf-gate-evidence`** (script, not an agent): pushes the branch so lefthook's pre-push hook runs gantry's checks
     (no CLAUDE.md parsing; Shin 2026-11-15); bug work needs a test-only commit before the fix (shell tests and bats count). Then opens or reuses the draft PR by branch (idempotent; `Closes #N`, opening-a-pr body with
     `## Scope`). Fail -> one retry with the exact reason; same rejection twice -> stop.
   - **review** (Codex, cross-model): tier depth (low/medium `/code-review`; high blast-radius +
     interrogate). Posts `Covered:` / `Findings:` as a PR comment. Empty = not run.
     No Codex access -> skipped automatically with "Codex review not run: <reason>" (Shin, 2026-11-15). Max 2 rounds;
     `Unbuildable:` never reworks.
   - **verify** (high tier only; fresh Opus that never sees builder reasoning): posts verdict JSON
     `{pr, head_sha, verdict, evidence}`. Reruns once per head if missing (#186).
   - **`sf-ship`** (script): reruns evidence + `sf-verdict-check` (head_sha == branch head) itself,
     waits up to 10 min on pending/UNKNOWN checks (pr-landing-mode lesson), then per `shinstack-mode`:
     auto merges `gh pr merge --squash --match-head-commit` (never --admin/--auto); supervised parks.
     Conflict -> rebase once (rebase marker on the PR), force-with-lease, re-run review+verify;
     second conflict -> stop (#34).
   - **debrief** (Haiku): project lessons -> `docs/solutions/`; general lessons -> `~/.claude/shinstack-friction.md`.
5. **`sf-stop`** is the only failure exit: comment `shinfactory: stopped. <reason>`, swap `ready` ->
   `needs-shin`, exit non-zero if any step failed so the next fire retries it (#161).
   Usage limit -> hold marker with reset time; never switch runtime or account; never fail (#50).
6. **triage.** Shin's interactive chat: walks `needs-shin` issues one at a time; only it re-adds `ready`.

## Labels (one state label per issue)
Inbox (none) / `ready` / `needs-shin` / `icebox` / closed. Plus `risk:high` (forces verify) and type
labels. Issue body: Goal / Done when / Out of scope / Decided / Assumed / Open.

## Carried over
Only `ready` builds; one issue = one branch = one PR; the PR is the human gate; models by role
(Haiku foreman/debrief, Sonnet build, Codex review, Opus plan/verify); fail loudly, no fallback
runtime (#86); stages never edit or comment on issues (shinstack b42a326); factory files are risk:high;
check CI run dates (#226); no "I'll check back" without an armed wakeup (#256); working around a factory
fault means filing an issue in the same step (#254); tests must never call real `gh` (guard in test harness).

## Dropped
Go loop and tests, dashboard (Orca is the UI), mise/orders/reducer/projection/snapshot,
sprites/cursor/process runtimes, $ spend cap (read $0.00 on Orca, #219; attempt cap 3 stays),
steer box, brain/meditate, reused foreman session.

## shinstack changes (PR in shinstack)
- Replace the `NOODLE_WORKTREE` contract in skills/craft with `SHINFACTORY_ROLE=<station>`.
- Remove shinstack's .noodle.toml, copied .agents/skills, adapters/github/backlog-*.
- Update docs/decisions/shinstack-vs-shinfactory.md: "who" moves to Orca; factory keeps when + policy.
- Point autopilot/orchestrate "Make it enforceable (factory)" notes at the gates.

## Config (repo CLAUDE.md, next to shinstack-mode)
`shinfactory-concurrency: 2`, `shinfactory-sensitive: false`.

## Build order
0. **Spike by hand.** Push one real issue through with the Orca CLI only (run-create, task-create with
   deps, worker-start), with no foreman. Answers: can Runs and tasks outlive the session that created them,
   and can a fresh session read and advance them? Write findings to docs/decisions/.
1. **shinstack contract PR** (`SHINFACTORY_ROLE`) so workers behave as stations.
2. **Gates:** sf-state, sf-precheck, sf-stop, sf-ship here; evidence + verdict-check in gantry. Tests
   drive them with fixture repos and a fake `gh`/`orca` on PATH.
3. **Stations + worker brief template.**
4. **foreman + automation + sf-init** (labels, automation, CLAUDE.md lines).
5. **triage, plan, debrief.**
6. **Cutover:** shinstack repo first, then shinfactory. Stop the Go loop; archive the shinfactory repo
   README to point here.

## Done when
- a `ready` issue becomes a merged PR (auto mode) with a Codex review and a verdict comment, no human;
- an issue with no Done when ends `needs-shin` with a comment;
- two concurrent fires plus a kill mid-Run produce one Run and one PR;
- `gh` failing during a stop produces no new Run on the next fire;
- re-readying a stopped issue starts a fresh attempt count;
- the Go loop is not running anywhere.

## Decided after v2 (Shin, 2026-11-15)
- Sensitive repos may run on Orca (drops shinfactory#57's rule). `shinfactory-sensitive: true` still keeps review on the same provider with synthetic data.
- This repo runs `shinstack-mode: auto`.
- After cutover, keep shinfactory open until its open issues are triaged, then archive it.

## Open
- Spike answers (step 0) may change the foreman design.

## Advisor review (Fable, 2026-11-15): applied
- Attempts from GitHub markers since last `ready`, not Run count (Run count never resets).
- dead Run + no needs-shin = owes a stop.
- Fresh session per fire + mkdir lock + `sf-state` emits actions (was: one reused session).
- ship is a script that reruns gates; generic gates go to gantry.
- Added: 10-min pending-checks wait, stale branch cleanup, PR reuse by branch, fake-gh test guard.
- Build order: hand spike first, shinstack contract before stations, cut over shinstack first.
- Not applied: "cut plan/debrief/triage/sensitive/config for v1". Shin asked for the full build, so
  they are sequenced last (step 5) instead.

## Where each check lives (Shin, 2026-11-15)
Check definitions live once, in gantry. Each repo holds only pointers: `lefthook.yml` (pulls gantry's hooks) and a
thin `ci.yml` (calls gantry's workflow). The repo's own `package.json` / scripts define what "test" means. The factory
adds one check only it can do (bug has a test commit first). Agents iterate on local hooks for free; CI runs once when
the PR leaves draft (gantry#125).

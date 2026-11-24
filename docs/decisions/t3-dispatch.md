# Dispatch on T3 Code instead of Orca (issue #112)

Date: 2026-11-24. Status: accepted by Shin ("replace Orca outright"). Supersedes `orca-run-lifecycle.md`
for how stations are started and read; the station contracts are unchanged.

## Why

The factory started stations as Orca workers through the `orca` CLI. In a T3 Code session that
precondition doesn't hold, so a builder started there ran as a plain child with no evidence gate,
review station or auto-merge. The gates themselves (sf-ship, sf-hold, sf-stop, gantry, the
`factory-result:` line) read only GitHub, so only the dispatch layer is Orca-specific.

## The constraint

T3 exposes `delegate_task`, `task_status`, `t3_thread_read`, `t3_thread_list`, `schedule_task`,
worktree isolation and PR link/watch as MCP tools. A POSIX shell script cannot call them. So the
shell scripts keep deciding and gating, and an agent session does the dispatching.

## Decision

1. **The foreman is an agent.** `factory:foreman` runs as a T3 scheduled task (`schedule_task`,
   every 5 minutes, in the repo) in place of the Orca automation and `sf-tick`. Each fire is
   stateless and converges: it reads state, does the next actions, exits.
2. **Shell decides, agent dispatches.** `sf-state` prints the actions as now. `sf-act` carries out
   the GitHub-only ones (comments, labels, merge via `sf-ship`). For an action that needs a worker,
   `sf-act` prints one `{"dispatch": ...}` request (station, brief, branch, model) instead of
   calling Orca; the foreman answers it with `delegate_task` (`isolation: worktree`), then records it.
3. **State is GitHub plus the T3 thread list.** No local state file.
   - A dispatch is a marker comment on the issue: `<!-- factory:dispatch {"station":..,"round":..,"thread":..} -->`.
   - A finished station's `factory-result:` line is read by the foreman with `t3_thread_read` and
     posted as a `<!-- factory:result ... -->` comment. `sf-state` and `sf-act` then read results
     from GitHub, not from T3.
   - Liveness (a worker that stopped without reporting) comes from the thread list, which the foreman
     passes to `sf-state` on stdin as JSON. A thread the list can't account for counts as "unknown",
     like `live_worker` does today: retry next fire, never assume gone.
4. **Contracts do not change.** Result-line JSON shapes, the evidence gate, the Opus verifier,
   the round limit, "merge only on a green gate with `--match-head-commit`".
5. **Cleanup** (closed issue, Run over): `sf-act` emits a `cleanup` request with the worktree path;
   the foreman removes it with the T3 worktree tools, then confirms.
6. **Review model.** The review station runs as a T3 child on a Codex model where the host offers one.
7. **Orca is removed**, not kept behind a flag (CLAUDE.md: no backward compatibility).

## Seam

`lib/orch.sh` (PR #114) holds every call to the dispatch layer behind `orch_*` functions. The
T3 implementation replaces the Orca one behind the same names; request/response goes through the
foreman as above. The Orca implementation and its fakes are deleted in the last PR.

## Order

1. Seam in `lib/orch.sh` (#114). 2. This doc. 3. Markers and the thread snapshot in `sf-state`, with fakes.
4. `factory:foreman` skill and the T3 scheduled task in `sf-init`. 5. Station skills and brief:
"Runs as: T3 child", result by thread read. 6. Delete Orca, update docs and metadata, release 0.4.0.

## Open until step 3 is built

- Whether the thread list shows a stopped-without-report worker clearly enough to replace the Orca
  inbox signal. If not, the foreman reads the thread's last event per dispatched task.
- How the review station gets a Codex model when the host has none (fall back to Opus, say so in the comment).

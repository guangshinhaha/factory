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
3. **State is GitHub plus the T3 thread list.** No local state file. See "Records" below for
   the formats (PR 3).
   - Runs, tasks, dispatches and results are marker comments on the issue.
   - The foreman reads a finished station's `factory-result:` line with `t3_thread_read` and posts
     it as a `result` marker. `sf-state` and `sf-act` then read results from GitHub, not from T3.
   - Liveness comes from the thread list. The foreman writes it to a per-fire temp file named by
     `FACTORY_T3_THREADS`. A thread the list doesn't show counts as "unknown", as `live_worker`
     does today: retry next fire, never assume gone.
4. **Contracts do not change.** Result-line JSON shapes, the evidence gate, the Opus verifier,
   the round limit, "merge only on a green gate with `--match-head-commit`".
5. **Cleanup** (closed issue, Run over): `sf-act` emits a `cleanup` request with the worktree path;
   the foreman removes it with the T3 worktree tools, then confirms.
6. **Review model.** The review station runs as a T3 child on a Codex model where the host offers one.
7. **Orca is removed**, not kept behind a flag (CLAUDE.md: no backward compatibility).

## Seam

`lib/orch.sh` (PR #114) holds every call to the dispatch layer behind `orch_*` functions.
PR 3 added `lib/orch-t3.sh` with the same function names, arguments, exit codes and output shapes,
behind a temporary switch. PR 6 removed the switch and the Orca implementation: `lib/orch.sh` is now
the contract and sources `lib/orch-t3.sh`.

## Records (PR 3)

Every record is a comment by OWNER, MEMBER or COLLABORATOR whose last line is the existing marker
grammar, `<!-- factory:{"kind":...} -->`. That gives one grammar and one parser. Kinds the older
readers don't know are ignored by them. A `>` inside the JSON is written `\u003e`, so a brief can't
close the HTML comment early. All comments on the repo are read in one paginated
`gh api repos/<repo>/issues/comments` call per process, then cached in that process's temp dir.

| kind | fields | written by |
|---|---|---|
| `run` | `run`, `objective` (`factory <repo>#<n>`) | `orch_run_create` |
| `task` | `run`, `task`, `title`, `deps` (ids), `spec` (the brief) | `orch_task_create` |
| `dispatch` | `task`, `dispatch`, `agent`, `model`, `worktree` | `orch_worker_start` |
| `status` | `task`, `status` (`completed`, `failed` or `ready`), `result`? | `orch_task_complete`, `_fail`, `_ready` |
| `result` | `dispatch`, `outcome` (`succeeded`, or anything else to fail), `body` | the foreman |

- **Ids.** A Run is `t3.<issue>.<UTC yyyymmddHHMMSS>`, a task `<run>.<k>`, a dispatch `<task>.d<k>`.
- **Status** is folded in comment order, as in Orca. A task starts `pending` and becomes `ready`
  once all its deps are `completed`. A `dispatch` marker makes it `dispatched`. The first `result`
  for its current dispatch makes it `completed` or `failed`, and later results are ignored. A
  `status` marker sets the status directly.
- **Thread snapshot** (`$FACTORY_T3_THREADS`): `{"threads":[{"id","title","status","updatedAt","lastMessage"}]}`,
  taken from `t3_thread_list`. A thread belongs to the dispatch whose id ends its title in brackets
  (`acme/app#7 build [D]`). If several match, a live one wins. A missing or malformed snapshot fails
  inbox and worktree reads, and makes liveness unknown.

## Requests (PR 3)

Calls that must make something happen in T3 append one JSON line to the per-fire file
`$FACTORY_T3_REQUESTS`. The foreman reads that file after `sf-act` exits. A line is written once per
file. Repeat calls are idempotent: a second `orch_worker_start` reuses the task's open dispatch and
posts no new marker. A dispatch whose thread is still missing is requested again by the next fire's
inbox read, so a crashed fire converges.

```json
{"dispatch":{"id":D,"title":"<repo>#<n> <task title> [D]","repo":R,"issue":N,"run":RUN,"task":T,
             "station":"build","agent":"claude","model":"sonnet","worktree":"<dir>","brief":"<spec>"}}
{"stop":{"dispatch":D,"thread":TH|null,"title_suffix":"[D]"}}
{"send":{"dispatch":D,"thread":TH|null,"title_suffix":"[D]","subject":S,"body":B}}
{"cleanup":{"repo":R,"issue":N,"worktree":"<dir>","branch":"<name>-<n>","threads":[{"dispatch":D,"thread":TH|null}]}}
```

- The foreman must give the thread the request's `title`, because that is how the snapshot finds it.
- Worktrees are plain `git worktree` checkouts at `<checkout>.worktrees/<name>`, created and removed
  by the script itself. `sf-act` needs the path at once (`prep` reads it back), so this cannot wait
  for a request. Removal refuses a dirty tree, and the branch is deleted only if it is merged
  (`git branch -d`). `cleanup` tells the foreman to archive the listed threads.
- The seam has no terminal or automation verbs; the schedule is a `schedule_task` call (PR 4).

## Stopped without reporting

The thread list can't say "stopped without reporting" by itself. All it shows is a thread whose
turn ended (`completed` or `idle`). `orch_inbox` raises Orca's escalation for a dispatched task
whose thread has ended and which has no `result` marker. Its `created_at` is the thread's
`updatedAt`, which `sf-state` compares with the nudge marker. So the foreman must post the result
markers for every finished thread (from `t3_thread_read`) **before** it runs `sf-act`. Otherwise a
finished station reads as silent and gets nudged. The snapshot must carry `updatedAt`, or repeat
escalations can't be ordered. Station threads that ended `failed`, `interrupted`, `cancelled` or
`rolled_back` show up as a worktree agent with outcome `failure` (the retry path). Intake and plan
have no worktree row, so any finished intake or plan thread escalates instead.

## Order

1. Seam in `lib/orch.sh` (#114). 2. This doc. 3. Markers and the thread snapshot in `sf-state`, with fakes.
4. `factory:foreman` skill and the T3 scheduled task in `sf-init`. 5. Station skills and brief:
"Runs as: T3 child", result by thread read. 6. Delete Orca, update docs and metadata, release 0.4.0.

## Open

- How the review station gets a Codex model when the host has none (fall back to Opus, say so in the comment).

# Orca Run lifecycle (spike #10)

Date: 2026-11-15. Orca CLI at /Applications/Orca.app (ORCA_APP_VERSION of that day).
Method: one Run (`run_0b064faaa37e`) with tasks `build -> review`, driven by hand from three
different callers: a throwaway terminal that exited, this chat, and an automation precheck.
Tasks were synthetic (write a file, say "reviewed") so nothing touched shinfactory or shinstack.

## Answers

### 1. Do a Run and its tasks outlive the session that created them? Yes.
A terminal ran `run-create` + two `task-create` (review `--deps` on build) and exited.
Afterwards, from a different session:
```
$ orca orchestration task-list --run run_0b064faaa37e --json
{"tasks":[{"id":"task_7a69772de5b4","status":"pending","title":"review","deps":"[\"task_d638a1d1e1c3\"]"},
          {"id":"task_d638a1d1e1c3","status":"ready","title":"build"}]}
```
When build reported `worker_done`, review flipped to `ready` on its own.

### 2. Can a fresh session list the tasks and start the next ready one? Yes, after `run-use`.
Without binding:
```
$ orca orchestration worker-start --run run_0b064faaa37e --task task_d638a1d1e1c3 ...
error: consumer_fenced: worker-start needs the coordinator bound to the Run, or a worker on an active Dispatch in it.
```
After `orca orchestration run-use --id run_0b064faaa37e`, the same command returned
`{"dispatchId":"ctx_0e8b63cbce86","state":"ready",...}`.
A plain shell script in an Orca terminal (no agent) did the same: `run-use`, `task-list --ready`,
`worker-start` for review, exit 0.

**Binding is exclusive.** The script's `run-use` took the Run from this chat; this chat's next `send`
was refused with `consumer_fenced`. The last caller to `run-use` is the coordinator.

### 3. Where does `worker_done` go when the coordinator is gone? To the Run's inbox, kept.
Mail is addressed `-> run:<run_id>`, not to a session. With the binding script exited, review's
`worker_done` stayed in the Run inbox:
```
$ orca orchestration inbox --terminal run:run_0b064faaa37e --limit 10 --json
worker_done | structworker_e9bb... -> run:run_0b064faaa37e | reviewed
worker_done | structworker_c702... -> run:run_0b064faaa37e | Spike build: wrote spike-build.txt
```
It was delivered as a chat message to the next caller that ran `run-use`. Task status
(`completed`) is also readable with `task-list`, so the factory never needs to consume mail to know state.

### 4. Does `orca reference add/find` link an issue to the Run? It links to the workspace, not the Run.
```
$ orca reference add https://github.com/guangshinhaha/factory/issues/10 --worktree id:<repo>::<path>
$ orca reference find https://github.com/guangshinhaha/factory/issues/10 --json
matches: [{reference: {number: 10, ...}, workspace: {id: "<repo>::.../spike-10-build", name: "spike-10-build"}, agents: [...]}]
```
`worktree create --reference <url>` links at creation too (used for #2's worker).
Agents in the match show `linked: false` unless Orca recorded the session itself.
`run-list` returns `{id, objective}` only, so the issue -> Run join is the Run objective.

### 5. Can an automation precheck read the repo, and what does non-zero do?
The precheck runs with cwd = the automation's `--workspace` path, the user's full PATH, and
working `gh` (`gh api user` succeeded) and `orca`. Non-zero exit records `skipped_precheck` and starts no agent:
```
$ orca automations runs --id <automation> --json   ->  ['skipped_precheck', 'skipped_precheck', 'skipped_precheck', 'skipped_precheck']
```
**But a precheck has no terminal identity.** Read-only orchestration commands work (`task-list`);
binding does not:
```
$ orca orchestration run-use --id run_0b064faaa37e      # from inside the precheck
error: no_active_sender_terminal: Could not determine the calling terminal ... run the command inside a live Orca terminal with ORCA_TERMINAL_HANDLE set.
```
Workaround, verified: the precheck runs `orca terminal create --worktree <main checkout> --command "<act script>; exit"`.
The act script runs in a real Orca terminal, so `run-use` and `task-create` succeed
(`{"taskId":"task_2ae0a52cf48b","status":"ready"}`), and the terminal closes when the script exits.

### 6. Does a worker inherit env vars? No.
`SHINFACTORY_ROLE=envprobe orca orchestration worker-start ...` -> the worker printed `ROLE=[]`.
Workers get Orca's environment, not the caller's. The role has to travel in the brief text.

## Decisions for the build

- **No long-lived coordinator.** Runs, tasks, deps and mail all persist in Orca. Keep the daemon-less design.
- **`sf-tick` splits in two.** `sf-tick` (the precheck) reads GitHub + Orca, decides, and if there is
  anything to do spawns `sf-act` with `orca terminal create`; then exits non-zero. `sf-act` does
  `run-use` + `task-create`/`worker-start` per Run and exits. Zero tokens still holds. (#7)
- **Re-bind every time.** Since binding is exclusive and last-writer-wins, `sf-act` runs `run-use` before
  each mutation on a Run and never assumes it still holds one.
- **State from `task-list`, not mail.** `sf-state` reads task status per Run; it never runs `check`
  (which would consume mail). Mail stays for Shin to read in Orca. (#3)
- **Issue -> Run join = Run objective.** Objective is `factory <owner>/<repo>#<n>`; `sf-state` matches it
  from `run-list`. Workspaces get `--reference <issue url>` for humans. (#3)
- **Role in the brief, not env.** The brief's first line is `factory-role: <station>`; shinstack's
  router keys off that instead of `NOODLE_WORKTREE`/`SHINFACTORY_ROLE` env. (#1)

## Not tested
- Orca restart mid-Run (Runs survived session exit; app restart not exercised).
- `sf-act` terminals racing each other on the same Run (the `mkdir` lock in `sf-tick` should prevent it).

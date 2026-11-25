# shellcheck shell=sh
# The orchestrator adapter: every call the factory makes to its worker host (T3 Code) goes through a
# function here, so the gate scripts name no host. Sourced by sf-state and sf-act, never run.
# This file is the contract; lib/orch-t3.sh implements it. The sourcing script sets `root` to the
# plugin dir.
#
# Conventions. Exit 0 means the call worked; non-zero means it did not, with the cause on stderr.
# Every JSON-printing function prints one JSON document. "Result" means the
# `{"ok":true,"result":{...}}` envelope, where the caller reads `.result`.
#
# Runs (one per issue; objective `factory <owner>/<repo>#<n>`):
#   orch_run_list                   this repo's Runs. Prints Result {"runs":[{"id":S,"objective":S,"created_at":S,...}]}
#                                   (the shape sf-state checks: one document, `runs` an array, string id/objective).
#   orch_run_create <objective>     make a Run. Prints Result {"runId":S} (sf-act reads `.result.runId`).
#   orch_run_bind <run>             make this caller the Run's coordinator, before every mutation. Output unused.
# Tasks:
#   orch_task_list <run>            Prints Result {"tasks":[{"id":S,"title":S,"status":S,...}]}.
#   orch_task_list_full <run>       Prints Result {"tasks":[{"id":S,"task_title":S,"deps":S,"status":S,"result":S|null}]};
#                                   deps is a JSON array as text; a worker's result is the JSON text
#                                   {"provenance":"worker","outcome":S,"body":S}.
#   orch_task_create <run> <title> <deps>   spec on stdin; deps is a JSON array of task ids, as text.
#                                   Prints Result {"taskId":S}.
#   orch_task_complete <task> <result>      status completed, with the result text. Output unused.
#   orch_task_fail <task> <result>          status failed, with the result text. Output unused.
#   orch_task_ready <task>                  status ready. Output unused.
#   orch_dispatch_show <task>       the task's last dispatch. Prints Result {"dispatch":{"id":S,...}}; a task
#                                   with no dispatch prints no `dispatch.id`. Non-zero when it can't be read.
# Workers (one agent session per dispatch):
#   orch_worker_start <task> <agent> <model> <worktree> <run>   worktree is a `path:<dir>` selector.
#                                   Prints Result {"dispatchId":S,...}. Non-zero when the start is refused.
#   orch_worker_show <dispatch>     liveness. Non-zero with `dispatch_not_found` in its output when the
#                                   dispatch is gone; any other non-zero means unknown.
#   orch_worker_read <dispatch>     the worker's last text as JSON, newest last.
#   orch_worker_stop <dispatch>     end the worker. Output unused.
#   orch_worker_send <dispatch> <run> <subject> <body>   message a live worker. Output unused.
#   orch_inbox <run>                the Run's mail. Prints Result {"messages":[{"type":S,"subject":S,"payload":S,"created_at":S,...}]}.
# Worktrees:
#   orch_worktree_ps                every worktree. Prints Result {"worktrees":[{...}]} (the shape sf-state checks).
#   orch_worktree_create <name> <main> <base> <branch> <issue>   a worktree of the repo at <main> on a new
#                                   branch for the issue. Output unused.
#   orch_worktree_rm <worktree>     remove it, and its branch when merged. Output unused.

# shellcheck source=lib/orch-t3.sh disable=SC2154 # root comes from the caller
. "$root/lib/orch-t3.sh"

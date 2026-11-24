# shellcheck shell=sh
# The orchestrator adapter: every call the factory makes to its worker host goes through a function
# here, so the gate scripts name no host CLI. Sourced by sf-state, sf-act, sf-tick and sf-init, never run.
# The one implementation today calls the `orca` CLI. A second implementation must keep these names,
# arguments, exit codes and stdout shapes.
#
# Conventions. Each function runs one host command and passes its stdout, stderr and exit status
# through untouched, so the caller picks the redirections and the error wording. Exit 0 means the host
# answered; non-zero means it did not. Every JSON-printing function prints one JSON document.
# "Result" means the host's `{"ok":true,"result":{...}}` envelope, where the caller reads `.result`.
#
# Runs (one per issue; objective `factory <owner>/<repo>#<n>`):
#   orch_run_list [cursor]          one page (100) of Runs. Prints {"runs":[{"id":S,"objective":S,...}], "nextCursor"?:S}
#                                   (the page shape sf-state checks: one document, `runs` an array, string id/objective).
#   orch_run_create <objective>     make a Run. Prints Result {"run":{"id":S}} (the id is `.result.run.id`).
#   orch_run_bind <run>             make this caller the Run's coordinator. Binding is exclusive and
#                                   last-writer-wins, so call it before every mutation. Output unused.
# Tasks:
#   orch_task_list <run>            Prints {"tasks":[{"id":S,"title":S,"status":S,"deps":S,...}]}.
#   orch_task_list_full <run>       The same, with each task's `result` text.
#   orch_task_create <run> <title> <deps>   spec on stdin; deps is the host's dependency list text.
#                                   Prints Result {"taskId":S}.
#   orch_task_complete <task> <result>      status completed, with the result text. Output unused.
#   orch_task_fail <task> <result>          status failed, with the result text. Output unused.
#   orch_task_ready <task>                  status ready. Output unused.
#   orch_dispatch_show <task>       the task's last dispatch. Prints Result {"dispatch":{"id":S,...}}; a task
#                                   with no dispatch prints no `dispatch.id`. Non-zero when the host can't say.
# Workers (one agent session per dispatch):
#   orch_worker_start <task> <agent> <model> <worktree> <run>   worktree is a `path:<dir>` selector.
#                                   Prints Result {"dispatchId":S,...}. Non-zero when the start is refused.
#   orch_worker_show <dispatch>     liveness. Non-zero with `dispatch_not_found` in its output when the
#                                   dispatch is gone; any other non-zero means unknown.
#   orch_worker_read <dispatch>     the worker's terminal text as JSON, newest last.
#   orch_worker_stop <dispatch>     end the worker. Output unused.
#   orch_worker_send <dispatch> <run> <subject> <body>   message a live worker. Output unused.
#   orch_inbox <run>                the Run's mail, up to 500. Prints {"messages":[{"type":S,"subject":S,"body":S,...}]}.
# Worktrees:
#   orch_worktree_ps                every worktree, up to 1000. Prints {"worktrees":[{...}]} (the shape sf-state checks).
#   orch_worktree_create <name> <main> <base> <branch> <issue>   a worktree of the repo at <main> on a new
#                                   branch, linked to the issue, with no parent. Output unused.
#   orch_worktree_rm <worktree>     remove it and its branch. Output unused.
# Terminals:
#   orch_terminal_list <worktree>   Prints {"terminals":[{"handle":S,...}]}.
#   orch_terminal_close <terminal>  Output unused.
#   orch_terminal_create <worktree> <title> <command>   a terminal running the shell command line.
#                                   Output unused.
# Automations (the cron foreman):
#   orch_automation_list            Prints {"automations":[{"name":S,...}]}.
#   orch_automation_create <name> <cron> <prompt> <precheck> <workspace>   run <prompt> on the cron
#                                   schedule when the <precheck> command exits 0. Output unused.

orch_run_list() {
  if [ -n "${1:-}" ]; then
    orca orchestration run-list --json --full --limit 100 --cursor "$1"
  else
    orca orchestration run-list --json --full --limit 100
  fi
}
orch_run_create() { orca orchestration run-create --objective "$1" --json; }
orch_run_bind() { orca orchestration run-use --id "$1" --json; }

orch_task_list() { orca orchestration task-list --run "$1" --json; }
orch_task_list_full() { orca orchestration task-list --run "$1" --json --full; }
orch_task_create() { orca orchestration task-create --run "$1" --task-title "$2" --deps "$3" --spec-file - --json; }
orch_task_complete() { orca orchestration task-update --id "$1" --status completed --result "$2" --json; }
orch_task_fail() { orca orchestration task-update --id "$1" --status failed --result "$2" --json; }
orch_task_ready() { orca orchestration task-update --id "$1" --status ready --json; }
orch_dispatch_show() { orca orchestration dispatch-show --task "$1" --json; }

orch_worker_start() { orca orchestration worker-start --task "$1" --agent "$2" --model "$3" --worktree "$4" --run "$5" --json; }
orch_worker_show() { orca orchestration worker-show --dispatch "$1" --json; }
orch_worker_read() { orca orchestration worker-read --dispatch "$1" --source terminal --json; }
orch_worker_stop() { orca orchestration worker-stop --dispatch "$1" --json; }
orch_worker_send() {
  orca orchestration send --to "dispatch:$1" --run "$2" --subject "$3" --body "$4" --json
}
orch_inbox() { orca orchestration inbox --terminal "run:$1" --limit 500 --json --full; }

orch_worktree_ps() { orca worktree ps --json --limit 1000; }
orch_worktree_create() {
  orca worktree create --name "$1" --repo "path:$2" --base-branch "$3" --branch "$4" --issue "$5" --no-parent --json
}
orch_worktree_rm() { orca worktree rm --worktree "path:$1" --delete-branch --json; }

orch_terminal_list() { orca terminal list --worktree "path:$1" --json; }
orch_terminal_close() { orca terminal close --terminal "$1" --json; }
orch_terminal_create() { orca terminal create --worktree "path:$1" --title "$2" --command "$3" --json; }

orch_automation_list() { orca automations list --json; }
orch_automation_create() {
  orca automations create --name "$1" --trigger "$2" --provider claude \
    --prompt "$3" --precheck "$4" --workspace "path:$5" --json
}

# shellcheck shell=sh
# shellcheck disable=SC2016,SC2154 # jq programs in single quotes; repo and tmp come from the caller
# The T3 Code implementation of lib/orch.sh's functions (issue #112), sourced by lib/orch.sh. Names,
# arguments, exit codes and stdout shapes are the contract there. Formats: docs/decisions/t3-dispatch.md.
#
# A shell script cannot call T3's tools, so nothing here starts, stops or messages a worker:
#   - Runs, tasks, dispatches and results are marker comments on the issue (the existing
#     `<!-- factory:{"kind":...} -->` grammar, kinds run, task, status, dispatch, result), read back
#     with one repo-wide `gh api .../issues/comments` per process and folded into the contract's task model.
#   - Liveness comes from the T3 thread snapshot the foreman writes for each fire, a JSON file named
#     by FACTORY_T3_THREADS: {"threads":[{"id","title","status","updatedAt","lastMessage"}]}.
#     A thread belongs to dispatch D when its title ends with `[D]`.
#   - A worker start, stop or message, and a worktree's cleanup, is a one-line JSON request appended
#     to the file named by FACTORY_T3_REQUESTS, which the foreman carries out after sf-act. A
#     request line is written once per file, and a repeated start reuses the open dispatch, so a
#     fire that crashes midway converges.
#   - Worktrees are plain git worktrees (T3 can't put one on a named branch), next to the checkout.
# The caller sets `repo` (owner/repo) and `tmp` (its temp dir). The marker records are cached in
# $tmp/t3-records.jsonl (FACTORY_T3_CACHE, exported so a child sf-state reuses it); every marker
# this process posts is appended there too, so a read right after a write sees it.

t3_cr=$(printf '\r')
t3_trusted='["OWNER","MEMBER","COLLABORATOR"]'

# The fold: marker records ({issue, at, m}) in comment order into {runs, tasks{id: task}, disp{D: ...},
# results{D: ...}}. A pending task whose deps are all completed turns ready after every record. A result counts only for the task's current,
# still dispatched dispatch; only a dispatch's first result is read. A task, dispatch, result or status
# marker counts only on the issue of its Run (task) or task (the rest), never from another issue. A missing outcome is failed.
# threads: the snapshot's threads (an error when the snapshot is bad); thread(D): D's thread, a live
# one first. TERMINAL: thread statuses that mean the turn is over.
T3_DEFS='
def TERMINAL: ["completed","idle","interrupted","failed","cancelled","rolled_back"];
def promote: .tasks as $all | .tasks |= with_entries(
  if .value.status == "pending" and all(.value.deps[]; . as $d | $all[$d].status == "completed")
  then .value.status = "ready" else . end);
def fold: reduce .[] as $r ({runs: [], tasks: {}, disp: {}, results: {}};
  $r.m as $m
  | if $m.kind == "run" then
      if any(.runs[]; .id == $m.run) then . else .runs += [{id: $m.run, objective: $m.objective, created_at: $r.at}] end
    elif $m.kind == "task" then
      if .tasks[$m.task] != null or (any(.runs[]; .id == $m.run and (.objective | endswith("#\($r.issue)"))) | not) then .
      else .tasks[$m.task] = {id: $m.task, run: $m.run, issue: $r.issue, title: $m.title, deps: ($m.deps // []),
        spec: ($m.spec // ""), status: "pending", result: null, dispatch: null} end
    elif $m.kind == "dispatch" then
      if .tasks[$m.task] == null or .tasks[$m.task].issue != $r.issue or .disp[$m.dispatch] != null then .
      else .tasks[$m.task] |= (.status = "dispatched" | .dispatch = $m.dispatch)
        | .disp[$m.dispatch] = {task: $m.task, agent: $m.agent, model: $m.model, worktree: $m.worktree, at: $r.at} end
    elif $m.kind == "result" then
      $m.dispatch as $d | (if $m.outcome == "succeeded" then "succeeded" else "failed" end) as $o
      | if .disp[$d] == null or .tasks[.disp[$d].task].issue != $r.issue or .results[$d] != null then .
        else .results[$d] = {outcome: $o, body: ($m.body // "" | tostring)}
          | .disp[$d].task as $t
          | if .tasks[$t].dispatch == $d and .tasks[$t].status == "dispatched"
            then .tasks[$t] |= (.status = (if $o == "succeeded" then "completed" else "failed" end)
              | .result = ({provenance: "worker", outcome: $o, body: ($m.body // "" | tostring)} | tojson))
            else . end end
    elif $m.kind == "status" then
      if .tasks[$m.task] == null or .tasks[$m.task].issue != $r.issue or (["completed","failed","ready"] | index($m.status)) == null then .
      else .tasks[$m.task] |= (.status = $m.status | if ($m.result // "") != "" then .result = $m.result else . end) end
    else . end
  | promote);
def threads: if ($th | length) == 1 and ($th[0] | type) == "object" and ($th[0].threads | type) == "array"
  then $th[0].threads else error("orch-t3:snapshot") end;
def thread($d): [threads[] | select(type == "object" and ((.title // "") | type) == "string" and (.title | endswith("[\($d)]")))]
  | ((map(select(.status as $st | TERMINAL | index($st) | not)) | last) // last);
def marker: tojson | gsub(">"; "\\u003e");
'

t3_ok() { echo '{"ok":true,"result":{}}'; }
t3_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# t3_records: make sure the records file exists ($FACTORY_T3_CACHE), reading the repo's issue comments
# once. Each record is one trusted comment whose last non-empty line is a well-formed marker of a T3 kind.
t3_records() {
  if [ -z "${FACTORY_T3_CACHE:-}" ]; then
    if [ -z "${tmp:-}" ] || [ ! -d "$tmp" ]; then echo "orch-t3: no temp dir for the marker records (tmp unset)" >&2; return 1; fi
    FACTORY_T3_CACHE=$tmp/t3-records.jsonl
    export FACTORY_T3_CACHE
  fi
  [ ! -f "$FACTORY_T3_CACHE" ] || return 0
  gh api "repos/$repo/issues/comments?sort=created&direction=asc&per_page=100" --paginate > "$FACTORY_T3_CACHE.raw" \
    || { echo "orch-t3: issue comments of $repo not read (gh api failed)" >&2; return 1; }
  [ -s "$FACTORY_T3_CACHE.raw" ] || { echo "orch-t3: issue comments of $repo not read: gh api printed no output" >&2; return 1; }
  jq -cs --argjson trusted "$t3_trusted" '
    if all(.[]; type == "array") then (add // [])[] else error("orch-t3:shape") end
    | select(type == "object" and ((.author_association // "") as $a | $trusted | index($a)) != null)
    | ((.issue_url // "") | capture("/issues/(?<n>[0-9]+)$").n | tonumber) as $n
    | .created_at as $at
    | (.body // "" | split("\n") | map(rtrimstr("\r") | select(test("\\S"))) | last // "")
    | capture("^<!-- factory:(?<j>\\{.*\\}) -->$").j | (try fromjson catch empty)
    | select(type == "object" and (
        (.kind == "run" and (.run | type) == "string" and (.objective | type) == "string")
        or (.kind == "task" and (.task | type) == "string" and (.run | type) == "string" and (.title | type) == "string"
          and ((.deps // []) | type) == "array" and all((.deps // [])[]; type == "string"))
        or (.kind == "status" and (.task | type) == "string" and (.status | type) == "string")
        or (.kind == "dispatch" and (.task | type) == "string" and (.dispatch | type) == "string")
        or (.kind == "result" and (.dispatch | type) == "string")))
    | {issue: $n, at: $at, m: .}' "$FACTORY_T3_CACHE.raw" > "$FACTORY_T3_CACHE.new" 2> /dev/null \
    || { echo "orch-t3: issue comments of $repo not read: gh api printed no comment arrays" >&2; return 1; }
  mv "$FACTORY_T3_CACHE.new" "$FACTORY_T3_CACHE"
}

# t3_jq <jq args...>: jq over the records (slurped) with $th, the thread snapshot (no threads and
# $snap "no" when FACTORY_T3_THREADS names no readable file). Errors go to $FACTORY_T3_CACHE.err.
t3_jq() {
  if [ -n "${FACTORY_T3_THREADS:-}" ] && [ -r "$FACTORY_T3_THREADS" ]; then
    jq -s --slurpfile th "$FACTORY_T3_THREADS" --arg snap yes "$@" "$FACTORY_T3_CACHE" 2> "$FACTORY_T3_CACHE.err"
  else
    jq -s --argjson th '[{"threads":[]}]' --arg snap no "$@" "$FACTORY_T3_CACHE" 2> "$FACTORY_T3_CACHE.err"
  fi
}
# t3_why: the orch-t3:<why> a failed t3_jq raised, else its first stderr line.
t3_why() {
  _tw=
  IFS= read -r _tw < "$FACTORY_T3_CACHE.err" || :
  case $_tw in
    *orch-t3:*) _tw=${_tw##*orch-t3:} ;;
  esac
  printf '%s\n' "${_tw%"$t3_cr"}"
}
t3_snapshot_error() {
  echo "orch-t3: thread snapshot [${FACTORY_T3_THREADS:-}] not read: it is missing or has no threads array" >&2
}
# t3_fail <what>: the message for a failed t3_jq that may have read the snapshot.
t3_fail() {
  _tf_why=$(t3_why)
  if [ "$_tf_why" = snapshot ]; then t3_snapshot_error; else echo "orch-t3: $1: $_tf_why" >&2; fi
}

# t3_post <issue> <visible line> <marker json>: post the marker comment, then add its record to the cache.
t3_post() {
  _tp_body="$2

<!-- factory:$3 -->"
  [ "${#_tp_body}" -le 65000 ] || { echo "orch-t3: marker of ${#_tp_body} bytes does not fit an issue comment on #$1" >&2; return 1; }
  printf '%s\n' "$_tp_body" | gh issue comment "$1" -R "$repo" --body-file - > /dev/null \
    || { echo "orch-t3: marker comment not posted on #$1" >&2; return 1; }
  printf '{"issue":%s,"at":"%s","m":%s}\n' "$1" "$(t3_now)" "$3" >> "$FACTORY_T3_CACHE"
}

# t3_request <json line>: append the request for the foreman, once per request file.
t3_request() {
  [ -n "${FACTORY_T3_REQUESTS:-}" ] || { echo "orch-t3: FACTORY_T3_REQUESTS is not set: no request file for the foreman" >&2; return 1; }
  if [ -f "$FACTORY_T3_REQUESTS" ] && grep -Fqx -- "$1" "$FACTORY_T3_REQUESTS"; then return 0; fi
  printf '%s\n' "$1" >> "$FACTORY_T3_REQUESTS" || { echo "orch-t3: request not written to $FACTORY_T3_REQUESTS" >&2; return 1; }
}

# ---- Runs -----------------------------------------------------------------------------------------
# Runs are this repo's only.

orch_run_list() {
  t3_records || return 1
  t3_jq -c "$T3_DEFS"'fold | {ok: true, result: {runs: .runs}}' \
    || { echo "orch-t3: Runs not listed: $(t3_why)" >&2; return 1; }
}

orch_run_create() {
  case "$1" in
    "factory $repo#"*) _rc_n=${1##*#} ;;
    *) echo "orch-t3: objective [$1] is not factory $repo#<issue>" >&2; return 1 ;;
  esac
  case "$_rc_n" in '' | *[!0-9]*) echo "orch-t3: objective [$1] names no issue number" >&2; return 1 ;; esac
  t3_records || return 1
  _rc_id=t3.$_rc_n.$(date -u +%Y%m%d%H%M%S)
  t3_post "$_rc_n" "factory: Run $_rc_id opened." "{\"kind\":\"run\",\"run\":\"$_rc_id\",\"objective\":\"factory $repo#$_rc_n\"}" || return 1
  printf '{"ok":true,"result":{"runId":"%s","run":{"id":"%s"}}}\n' "$_rc_id" "$_rc_id"
}

orch_run_bind() { t3_ok; }

# ---- Tasks ----------------------------------------------------------------------------------------

orch_task_list() {
  t3_records || return 1
  t3_jq -c --arg r "$1" "$T3_DEFS"'fold | if any(.runs[]; .id == $r) then . else error("orch-t3:run not found: \($r)") end
    | {ok: true, result: {tasks: [.tasks[] | select(.run == $r) | {id, title, status}], runId: $r}}' \
    || { echo "orch-t3: tasks not listed: $(t3_why)" >&2; return 1; }
}

orch_task_list_full() {
  t3_records || return 1
  t3_jq -c --arg r "$1" "$T3_DEFS"'fold | if any(.runs[]; .id == $r) then . else error("orch-t3:run not found: \($r)") end
    | {ok: true, result: {tasks: [.tasks[] | select(.run == $r)
        | {id, task_title: .title, display_name: "", deps: (.deps | tojson), status, result}]}}' \
    || { echo "orch-t3: tasks not listed: $(t3_why)" >&2; return 1; }
}

# orch_task_create <run> <title> <deps>: the task id is <run>.<k>, k counting the Run's tasks.
orch_task_create() {
  _tc_spec=$(cat)
  t3_records || return 1
  _tc_out=$(t3_jq -r --arg r "$1" --arg t "$2" --arg deps "$3" --arg spec "$_tc_spec" "$T3_DEFS"'fold
    | ((.runs[] | select(.id == $r)) // error("orch-t3:run not found: \($r)")) as $run
    | ($deps | try fromjson catch error("orch-t3:deps [\($deps)] are not a JSON array")) as $dl
    | if ($dl | type) != "array" then error("orch-t3:deps [\($deps)] are not a JSON array") else . end
    | "\($r).\([.tasks[] | select(.run == $r)] | length + 1)" as $id
    | ($run.objective | capture("#(?<n>[0-9]+)$").n),
      ({kind: "task", run: $r, task: $id, title: $t, deps: $dl, spec: $spec} | marker), $id') \
    || { echo "orch-t3: task $2 not created: $(t3_why)" >&2; return 1; }
  {
    IFS= read -r _tc_n
    IFS= read -r _tc_m
    IFS= read -r _tc_id
  } << EOF
$_tc_out
EOF
  _tc_n=${_tc_n%"$t3_cr"} _tc_m=${_tc_m%"$t3_cr"} _tc_id=${_tc_id%"$t3_cr"}
  t3_post "$_tc_n" "factory: task $2 queued." "$_tc_m" || return 1
  printf '{"ok":true,"result":{"taskId":"%s"}}\n' "$_tc_id"
}

# t3_status <task> <status> [result]: post the status marker.
t3_status() {
  t3_records || return 1
  _ts_out=$(t3_jq -r --arg t "$1" --arg s "$2" --arg res "${3:-}" "$T3_DEFS"'fold
    | (.tasks[$t] // error("orch-t3:task not found: \($t)")) as $k
    | $k.issue, $k.title, ({kind: "status", task: $t, status: $s} + (if $res != "" then {result: $res} else {} end) | marker)') \
    || { echo "orch-t3: task $1 not set $2: $(t3_why)" >&2; return 1; }
  {
    IFS= read -r _ts_n
    IFS= read -r _ts_title
    IFS= read -r _ts_m
  } << EOF
$_ts_out
EOF
  t3_post "${_ts_n%"$t3_cr"}" "factory: task ${_ts_title%"$t3_cr"} $2." "${_ts_m%"$t3_cr"}" || return 1
  t3_ok
}
orch_task_complete() { t3_status "$1" completed "$2"; }
orch_task_fail() { t3_status "$1" failed "$2"; }
orch_task_ready() { t3_status "$1" ready; }

orch_dispatch_show() {
  t3_records || return 1
  t3_jq -c --arg t "$1" "$T3_DEFS"'fold | .tasks[$t].dispatch as $d
    | {ok: true, result: {dispatch: (if $d then {id: $d} else null end)}}' \
    || { echo "orch-t3: dispatch of task $1 not read: $(t3_why)" >&2; return 1; }
}

# ---- Workers --------------------------------------------------------------------------------------

# orch_worker_start <task> <agent> <model> <path:dir> <run>: a ready task gets a new dispatch
# <task>.d<k> (a dispatch marker); a task already dispatched keeps its dispatch (a repeated start).
# Either way the dispatch request is written for the foreman.
orch_worker_start() {
  [ -n "${FACTORY_T3_REQUESTS:-}" ] || { echo "orch-t3: FACTORY_T3_REQUESTS is not set: no request file for the foreman" >&2; return 1; }
  t3_records || return 1
  _ws_out=$(t3_jq -r --arg t "$1" --arg a "$2" --arg m "$3" --arg w "${4#path:}" --arg repo "$repo" "$T3_DEFS"'fold
    | . as $s | ($s.tasks[$t] // error("orch-t3:task not found: \($t)")) as $k
    | (if $k.status == "dispatched" then {new: false, d: $k.dispatch} + ($s.disp[$k.dispatch] | {agent, model, worktree})
       elif $k.status == "ready" then {new: true, d: "\($t).d\([$s.disp[] | select(.task == $t)] | length + 1)", agent: $a, model: $m, worktree: $w}
       else error("orch-t3:task \($t) is \($k.status), not ready") end) as $x
    | (if $x.new then "new" else "reuse" end), $x.d, $k.issue, $k.title,
      ({kind: "dispatch", task: $t, dispatch: $x.d, agent: $x.agent, model: $x.model, worktree: $x.worktree} | marker),
      ({dispatch: {id: $x.d, title: "\($repo)#\($k.issue) \($k.title) [\($x.d)]", repo: $repo, issue: $k.issue, run: $k.run,
        task: $t, station: ($k.title | split(" ")[0]), agent: $x.agent, model: $x.model, worktree: $x.worktree, brief: $k.spec}} | tojson)') \
    || { echo "orch-t3: worker of task $1 not started: $(t3_why)" >&2; return 1; }
  {
    IFS= read -r _ws_mode
    IFS= read -r _ws_d
    IFS= read -r _ws_n
    IFS= read -r _ws_title
    IFS= read -r _ws_m
    IFS= read -r _ws_req
  } << EOF
$_ws_out
EOF
  _ws_d=${_ws_d%"$t3_cr"}
  if [ "${_ws_mode%"$t3_cr"}" = new ]; then
    t3_post "${_ws_n%"$t3_cr"}" "factory: ${_ws_title%"$t3_cr"} dispatched to a T3 thread ($_ws_d)." "${_ws_m%"$t3_cr"}" || return 1
  fi
  t3_request "${_ws_req%"$t3_cr"}" || return 1
  printf '{"ok":true,"result":{"dispatchId":"%s"}}\n' "$_ws_d"
}

# orch_worker_show <dispatch>: exited when the dispatch has a result or its thread's turn is over;
# alive otherwise. No dispatch marker is dispatch_not_found (gone); a dispatch whose thread the
# snapshot can't account for, or no snapshot, is a failure without it (unknown, never gone).
orch_worker_show() {
  t3_records || return 1
  _wsh=$(t3_jq -r --arg d "$1" "$T3_DEFS"'fold
    | if .disp[$d] == null then "notfound"
      elif .results[$d] != null then "exited"
      elif $snap != "yes" then "nosnap"
      else thread($d) as $th1 | if $th1 == null then "nothread"
        elif (TERMINAL | index($th1.status)) != null then "exited" else "alive" end end') \
    || { t3_fail "worker of dispatch $1 not read"; return 1; }
  case ${_wsh%"$t3_cr"} in
    notfound) echo "dispatch_not_found: dispatch $1 has no dispatch marker" >&2; return 1 ;;
    nosnap) t3_snapshot_error; return 1 ;;
    nothread) echo "orch-t3: thread of dispatch $1 not in the T3 thread snapshot: liveness unknown" >&2; return 1 ;;
  esac
  printf '{"ok":true,"result":{"dispatchId":"%s","liveness":"%s"}}\n' "$1" "${_wsh%"$t3_cr"}"
}

# orch_worker_read <dispatch>: the reported body, else the thread's last message, as JSON text.
orch_worker_read() {
  t3_records || return 1
  t3_jq -c --arg d "$1" "$T3_DEFS"'fold
    | {ok: true, result: {dispatchId: $d, text: (.results[$d].body // (if $snap == "yes" then (thread($d).lastMessage // "") else "" end))}}' \
    || { echo "orch-t3: worker of dispatch $1 not read: $(t3_why)" >&2; return 1; }
}

# t3_worker_request <dispatch> <jq object of extra fields>: the stop or send request for a dispatch
# with no result whose thread is not known to be over; nothing for an unknown or finished one.
t3_worker_request() {
  t3_records || return 1
  _wr=$(t3_jq -r --arg d "$1" --arg kind "$2" --arg subject "${3:-}" --arg body "${4:-}" --arg repo "$repo" "$T3_DEFS"'fold
    | if .disp[$d] == null or .results[$d] != null then empty
      else (if $snap == "yes" then thread($d) else null end) as $th1
        | if $th1 != null and (TERMINAL | index($th1.status)) != null and $kind == "stop" then empty
          else {($kind): ({dispatch: $d, thread: ($th1.id // null), title_suffix: "[\($d)]"}
            + (if $kind == "send" then {subject: $subject, body: $body} else {} end))} | tojson end end') \
    || { echo "orch-t3: $2 request for dispatch $1 not made: $(t3_why)" >&2; return 1; }
  [ -z "$_wr" ] || t3_request "${_wr%"$t3_cr"}" || return 1
  t3_ok
}
orch_worker_stop() { t3_worker_request "$1" stop; }
orch_worker_send() { t3_worker_request "$1" send "$3" "$4"; }

# orch_inbox <run>: an escalation "Worker stopped without reporting" for each dispatched task of the
# Run whose thread's turn is over with no result: completed or idle; failed, interrupted, cancelled
# or rolled back only for intake and plan (the other stations' worktree row witnesses that). Its time is the thread's updatedAt. A dispatched task whose thread the
# snapshot lacks gets its dispatch request again, so a start lost in a crash converges.
orch_inbox() {
  t3_records || return 1
  if [ "${FACTORY_T3_THREADS:+x}" != x ] || [ ! -r "$FACTORY_T3_THREADS" ]; then t3_snapshot_error; return 1; fi
  _ib=$(t3_jq -c --arg r "$1" --arg repo "$repo" --arg now "$(t3_now)" "$T3_DEFS"'fold | . as $s
    | [.tasks[] | select(.run == $r and .status == "dispatched" and .dispatch != null and $s.results[.dispatch] == null)
        | . as $k | {k: $k, th: thread($k.dispatch)}] as $open
    | {ok: true, result: {messages: [$open[] | select(.th != null)
        | (.k.title | split(" ")[0]) as $st
        | select(.th.status == "completed" or .th.status == "idle"
            or (($st == "intake" or $st == "plan") and (.th.status as $ts | TERMINAL | index($ts)) != null))
        | {type: "escalation", subject: "Worker stopped without reporting",
           payload: ({taskId: .k.id, dispatchId: .k.dispatch} | tojson), created_at: (.th.updatedAt // $s.disp[.k.dispatch].at)}]}},
      ($open[] | select(.th == null) | .k as $k | $s.disp[$k.dispatch] as $x
        | {dispatch: {id: $k.dispatch, title: "\($repo)#\($k.issue) \($k.title) [\($k.dispatch)]", repo: $repo, issue: $k.issue, run: $k.run,
            task: $k.id, station: ($k.title | split(" ")[0]), agent: $x.agent, model: $x.model, worktree: $x.worktree, brief: $k.spec}})') \
    || { t3_fail "inbox of Run $1 not read"; return 1; }
  _ib_first=1
  while IFS= read -r _ib_l; do
    _ib_l=${_ib_l%"$t3_cr"}
    if [ "$_ib_first" = 1 ]; then
      printf '%s\n' "$_ib_l"
      _ib_first=0
    elif [ -n "${FACTORY_T3_REQUESTS:-}" ]; then
      t3_request "$_ib_l" || return 1
    fi
  done << EOF
$_ib
EOF
}

# ---- Worktrees ------------------------------------------------------------------------------------

# orch_worktree_ps: the checkout's git worktrees as the contract's rows. linkedIssue comes from a factory
# branch name (<name>-<n>, debrief-<name>-<n>); agents are the open dispatches of that issue's tasks
# whose station works on that branch, with state done (turn over), running, or unknown (no thread),
# and outcome failure for a failed, interrupted, cancelled or rolled back thread.
orch_worktree_ps() {
  t3_records || return 1
  if [ "${FACTORY_T3_THREADS:+x}" != x ] || [ ! -r "$FACTORY_T3_THREADS" ]; then t3_snapshot_error; return 1; fi
  git worktree list --porcelain > "$FACTORY_T3_CACHE.wt" 2> /dev/null || { echo "orch-t3: git worktrees not listed (git worktree list failed)" >&2; return 1; }
  t3_jq -c --rawfile wt "$FACTORY_T3_CACHE.wt" --arg name "${repo#*/}" "$T3_DEFS"'fold | . as $s
    | def issue_of($b): ($b | ltrimstr("debrief-")) as $x
        | if ($x | startswith("\($name)-")) and ($x | ltrimstr("\($name)-") | test("^[0-9]+$")) then $x | ltrimstr("\($name)-") | tonumber else null end;
      def branch_of($k): ($k.title | split(" ")[0]) as $st
        | if $st == "debrief" then "debrief-\($name)-\($k.issue)"
          elif $st == "build" or $st == "review" or $st == "verify" then "\($name)-\($k.issue)" else null end;
    [$wt | gsub("\r"; "") | split("\n\n")[] | split("\n") | map(select(. != ""))
      | select(length > 0 and (.[0] | startswith("worktree ")))
      | {path: (.[0] | ltrimstr("worktree ")), branch: (map(select(startswith("branch "))) | .[0] // "" | ltrimstr("branch "))}] as $rows
    | {ok: true, result: {worktrees: [$rows | to_entries[] | .key as $i | .value
        | (.branch | ltrimstr("refs/heads/")) as $b | issue_of($b) as $n
        | {path, branch, repo: $name, isMainWorktree: ($i == 0), linkedIssue: $n,
           agents: (if $n == null then [] else [$s.tasks[] | select(.issue == $n and .status == "dispatched" and .dispatch != null and branch_of(.) == $b)
             | thread(.dispatch) as $th1
             | {mainAgent: {state: (if $th1 == null then "unknown" elif (TERMINAL | index($th1.status)) != null then "done" else "running" end),
                 outcome: (if $th1 != null and (["failed","interrupted","cancelled","rolled_back"] | index($th1.status)) != null then "failure"
                   elif $th1 != null and (TERMINAL | index($th1.status)) != null then "success" else null end)}}] end)}],
      truncated: false}}' \
    || { t3_fail "worktrees not listed"; return 1; }
}

# orch_worktree_create <name> <main> <base> <branch> <issue>: a git worktree on a new branch, in
# <main>.worktrees/<name> beside the checkout.
orch_worktree_create() {
  _wc_dir=$(dirname "$2")/$(basename "$2").worktrees
  mkdir -p "$_wc_dir" || { echo "orch-t3: worktree dir $_wc_dir not created" >&2; return 1; }
  git -C "$2" worktree add -q -b "$4" "$_wc_dir/$1" "$3" > /dev/null \
    || { echo "orch-t3: worktree $_wc_dir/$1 on branch $4 not created (git worktree add failed)" >&2; return 1; }
  t3_ok
}

# orch_worktree_rm <worktree>: write a cleanup request naming the threads that worked there (first,
# so a crash after the removal can't lose it), then remove the worktree (git refuses a dirty one)
# and its branch when merged. A path git no longer has is pruned.
orch_worktree_rm() {
  [ -n "${FACTORY_T3_REQUESTS:-}" ] || { echo "orch-t3: FACTORY_T3_REQUESTS is not set: no request file for the foreman" >&2; return 1; }
  t3_records || return 1
  _wr_b=$(git worktree list --porcelain 2> /dev/null | awk -v p="worktree $1" '$0 == p { f = 1; next } /^worktree / { f = 0 } f && /^branch / { print substr($0, 8); exit }')
  _wr_b=${_wr_b#refs/heads/}
  _wr_req=$(t3_jq -r --arg w "$1" --arg b "$_wr_b" --arg repo "$repo" "$T3_DEFS"'fold | . as $s
    | [.disp | to_entries[] | select(.value.worktree == $w) | .key] as $ds
    | {cleanup: {repo: $repo, issue: ([$s.tasks[] | select(.dispatch as $d | $ds | index($d)) | .issue] | first // null),
        worktree: $w, branch: (if $b == "" then null else $b end),
        threads: [$ds[] | {dispatch: ., thread: (if $snap == "yes" then thread(.).id // null else null end)}]}} | tojson') \
    || { echo "orch-t3: cleanup of worktree $1 not prepared: $(t3_why)" >&2; return 1; }
  t3_request "${_wr_req%"$t3_cr"}" || return 1
  if [ -d "$1" ]; then
    git worktree remove "$1" > /dev/null 2>&1 || { echo "orch-t3: worktree $1 not removed (uncommitted changes?)" >&2; return 1; }
  else
    git worktree prune > /dev/null 2>&1 || :
  fi
  if [ -n "$_wr_b" ]; then git branch -q -d "$_wr_b" > /dev/null 2>&1 || :; fi
  t3_ok
}

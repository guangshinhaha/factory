# shellcheck shell=sh
# shellcheck disable=SC2016,SC2119 # jq programs in single quotes; orch_run_list takes an optional run id
# lib/orch-t3.sh: the T3 orchestrator, called directly (in-process, as sf-state and sf-act source it)
# and through sf-act fire after fire in the world of test/t3_world.sh.

# shellcheck source=test/t3_world.sh
. "$FACTORY_ROOT/test/t3_world.sh"

# in_process: source the T3 functions here, as a script that set repo and tmp would.
in_process() {
  t3_world
  repo=$REPO
  tmp=$TEST_TMP/proc
  mkdir -p "$tmp"
  # shellcheck source=lib/orch-t3.sh
  . "$FACTORY_ROOT/lib/orch-t3.sh"
}
# next_process: a new script run: no cached records.
next_process() {
  unset FACTORY_T3_CACHE
  rm -rf "$tmp" && mkdir -p "$tmp"
}
# run_with_intake: a Run for #7 with an intake task and a route task after it; sets $run $it $rt.
run_with_intake() {
  run=$(orch_run_create "factory $REPO#7" | jq -r '.result.runId')
  it=$(printf 'factory-role: intake\nsee --> here\n' | orch_task_create "$run" intake '[]' | jq -r '.result.taskId')
  rt=$(echo inline | orch_task_create "$run" route "[\"$it\"]" | jq -r '.result.taskId')
}
nl='
'
comments_count() { wc -l < "$GH_SIM/comments.jsonl" | tr -d ' '; }

test_runs_and_tasks_are_listed_from_marker_comments() {
  in_process
  run_with_intake
  assert_eq "$run.1" "$it" "intake id"
  assert_eq "$run.2" "$rt" "route id"
  case "$run" in t3.7.*) ;; *) fail "Run id [$run] does not name issue 7" ;; esac
  next_process
  assert_eq "[{\"id\":\"$run\",\"objective\":\"factory acme/app#7\"}]" "$(orch_run_list | jq -c '[.result.runs[] | {id, objective}]')" "runs"
  assert_eq null "$(orch_run_list | jq -c '.result.nextCursor')" "cursor"
  assert_eq "intake:ready route:pending" "$(orch_task_list "$run" | jq -r '[.result.tasks[] | "\(.title):\(.status)"] | join(" ")')" "concise tasks"
  full=$(orch_task_list_full "$run")
  assert_eq "[\"$it\"]" "$(printf '%s' "$full" | jq -r '.result.tasks[1].deps')" "route deps as text"
  assert_eq null "$(printf '%s' "$full" | jq -c '.result.tasks[0].result')" "no result yet"
  # The spec survives the comment: its --> is escaped in the marker, so the HTML comment never ends early.
  assert_eq "factory-role: intake${nl}see --> here" "$(t3_q '.tasks[$t].spec' --arg t "$it")" "spec"
  fake_stdin | grep -Fq 'see --\u003e here' || fail "the spec's --> went into the comment unescaped"
  # A marker in a comment by someone without write access is not read.
  comment_as NONE 7 '{"kind":"run","run":"t3.7.1","objective":"factory acme/app#7"}'
  next_process
  assert_eq 1 "$(orch_run_list | jq '.result.runs | length')" "runs after an untrusted marker"
  # Completing intake promotes route; the status marker is a comment too.
  orch_task_complete "$it" "lessons" > /dev/null
  next_process
  assert_eq "completed ready" "$(orch_task_list "$run" | jq -r '[.result.tasks[].status] | join(" ")')" "after complete"
  no_orca_called
}

test_a_dispatched_thread_that_stopped_without_a_result_is_escalated_until_the_result_comes() {
  in_process
  run_with_intake
  d=$(orch_worker_start "$it" claude sonnet "path:$TEST_TMP/app" "$run" | jq -r '.result.dispatchId')
  assert_eq "$it.d1" "$d" "dispatch id"
  assert_eq "{\"dispatch\":{\"id\":\"$d\"}}" "$(orch_dispatch_show "$it" | jq -c .result)" "dispatch-show"
  # The thread is running: alive, no escalation.
  thread "$d" running
  next_process
  assert_eq alive "$(orch_worker_show "$d" | jq -r .result.liveness)" "running thread"
  assert_eq '[]' "$(orch_inbox "$run" | jq -c .result.messages)" "inbox while running"
  # Its turn ended and no result was posted: Orca's "stopped without reporting".
  thread "$d" completed 2026-11-03T00:00:00Z
  assert_eq exited "$(orch_worker_show "$d" | jq -r .result.liveness)" "completed thread"
  esc=$(orch_inbox "$run" | jq -c '.result.messages[0] | {type, subject, p: (.payload | fromjson), created_at}')
  assert_eq "{\"type\":\"escalation\",\"subject\":\"Worker stopped without reporting\",\"p\":{\"taskId\":\"$it\",\"dispatchId\":\"$d\"},\"created_at\":\"2026-11-03T00:00:00Z\"}" "$esc" "escalation"
  # A failed intake thread is escalated too (no worktree row witnesses intake).
  thread "$d" failed 2026-11-03T00:00:00Z
  assert_eq 1 "$(orch_inbox "$run" | jq '.result.messages | length')" "failed intake escalated"
  # The foreman posts the result: the task completes with Orca's worker report, the escalation ends.
  result_marker "$d" "$GO"
  next_process
  assert_eq '[]' "$(orch_inbox "$run" | jq -c .result.messages)" "inbox after the result"
  assert_eq "completed" "$(orch_task_list "$run" | jq -r '.result.tasks[0].status')" "intake"
  assert_eq "worker succeeded $GO" "$(orch_task_list_full "$run" | jq -r '.result.tasks[0].result | fromjson | "\(.provenance) \(.outcome) \(.body)"')" "result"
  assert_contains "$(orch_worker_read "$d" | jq -r .result.text)" '"status":"go"'
  # A second result for the same dispatch is not read; a result for no known dispatch is not either.
  result_marker "$d" "$GO" failed
  result_marker "$run.9.d1" "$GO"
  next_process
  assert_eq "completed" "$(orch_task_list "$run" | jq -r '.result.tasks[0].status')" "intake after a second result"
}

test_a_result_with_no_outcome_fails_the_task() {
  in_process
  run_with_intake
  d=$(orch_worker_start "$it" claude sonnet "path:$TEST_TMP/app" "$run" | jq -r '.result.dispatchId')
  comment_as OWNER 7 "{\"kind\":\"result\",\"dispatch\":\"$d\",\"body\":\"done\"}"
  next_process
  assert_eq failed "$(orch_task_list "$run" | jq -r '.result.tasks[0].status')" "intake"
}

test_a_thread_the_snapshot_lacks_is_unknown_never_gone() {
  in_process
  run_with_intake
  d=$(orch_worker_start "$it" claude sonnet "path:$TEST_TMP/app" "$run" | jq -r '.result.dispatchId')
  st=0
  orch_worker_show "$d" > "$TEST_TMP/w" 2>&1 || st=$?
  assert_eq 1 "$st" "worker-show status"
  if grep -q dispatch_not_found "$TEST_TMP/w"; then fail "a thread missing from the snapshot read as gone: $(cat "$TEST_TMP/w")"; fi
  assert_contains "$(cat "$TEST_TMP/w")" "not in the T3 thread snapshot"
  # No snapshot at all: unknown too, and inbox and worktree ps fail closed.
  FACTORY_T3_THREADS=$TEST_TMP/missing.json
  st=0
  orch_worker_show "$d" > "$TEST_TMP/w" 2>&1 || st=$?
  assert_eq 1 "$st" "worker-show status without a snapshot"
  if grep -q dispatch_not_found "$TEST_TMP/w"; then fail "no snapshot read as gone"; fi
  if orch_inbox "$run" > /dev/null 2>&1; then fail "inbox read without a snapshot"; fi
  if orch_worktree_ps > /dev/null 2>&1; then fail "worktree ps read without a snapshot"; fi
  # A snapshot that is not {"threads":[...]} is no snapshot.
  echo '{"items":[]}' > "$TEST_TMP/bad.json"
  FACTORY_T3_THREADS=$TEST_TMP/bad.json
  st=0
  orch_worker_show "$d" > "$TEST_TMP/w" 2>&1 || st=$?
  assert_eq 1 "$st" "worker-show status with a bad snapshot"
  assert_contains "$(cat "$TEST_TMP/w")" "thread snapshot"
  # Only a dispatch with no marker at all is gone.
  st=0
  orch_worker_show "$it.d7" > "$TEST_TMP/w" 2>&1 || st=$?
  assert_eq 1 "$st" "worker-show status of an unknown dispatch"
  assert_contains "$(cat "$TEST_TMP/w")" dispatch_not_found
}

test_a_repeated_start_keeps_one_dispatch_and_a_lost_start_is_requested_again() {
  in_process
  run_with_intake
  d=$(orch_worker_start "$it" claude sonnet "path:$TEST_TMP/app" "$run" | jq -r '.result.dispatchId')
  n=$(comments_count)
  req=$(requests_of dispatch)
  assert_eq "{\"id\":\"$d\",\"title\":\"acme/app#7 intake [$d]\",\"issue\":7,\"station\":\"intake\",\"agent\":\"claude\",\"model\":\"sonnet\"}" \
    "$(printf '%s' "$req" | jq -c '.dispatch | {id, title, issue, station, agent, model}')" "dispatch request"
  # The path's drive form differs on Windows (C:/... vs /tmp/...): compare its last component.
  assert_eq app "$(printf '%s' "$req" | jq -r '.dispatch.worktree' | sed 's,.*/,,')" "dispatch request worktree"
  assert_eq "factory-role: intake${nl}see --> here" "$(printf '%s' "$req" | jq -r .dispatch.brief)" "brief"
  # The same start again (a crashed fire's retry), in this fire and the next: same dispatch, no new marker.
  assert_eq "$d" "$(orch_worker_start "$it" claude sonnet "path:$TEST_TMP/app" "$run" | jq -r '.result.dispatchId')" "repeat in the fire"
  assert_eq 1 "$(requests_of dispatch | wc -l | tr -d ' ')" "request lines in the fire"
  next_process
  : > "$REQUESTS"
  assert_eq "$d" "$(orch_worker_start "$it" claude sonnet "path:$TEST_TMP/app" "$run" | jq -r '.result.dispatchId')" "repeat next fire"
  assert_eq "$n" "$(comments_count)" "comments after the repeats"
  assert_eq "$req" "$(requests_of dispatch)" "the same request next fire"
  # The foreman never made the thread: each fire's inbox read asks again, once.
  : > "$REQUESTS"
  orch_inbox "$run" > /dev/null
  orch_inbox "$run" > /dev/null
  assert_eq "$req" "$(requests_of dispatch)" "request from the inbox"
  # Once the thread exists, no more requests.
  : > "$REQUESTS"
  thread "$d" running
  orch_inbox "$run" > /dev/null
  assert_eq "" "$(requests_of dispatch)" "request with the thread listed"
  # A start with no request file is refused before any marker is posted.
  orch_task_ready "$rt" > /dev/null
  FACTORY_T3_REQUESTS=
  n=$(comments_count)
  if orch_worker_start "$rt" claude sonnet "path:$TEST_TMP/app" "$run" 2> "$TEST_TMP/err"; then fail "started with no request file"; fi
  assert_contains "$(cat "$TEST_TMP/err")" "FACTORY_T3_REQUESTS is not set"
  assert_eq "$n" "$(comments_count)" "comments after a refused start"
}

test_stop_and_send_are_requests_and_a_finished_thread_needs_no_stop() {
  in_process
  run_with_intake
  d=$(orch_worker_start "$it" claude sonnet "path:$TEST_TMP/app" "$run" | jq -r '.result.dispatchId')
  thread "$d" running
  orch_worker_stop "$d" > /dev/null
  orch_worker_stop "$d" > /dev/null
  orch_worker_send "$d" "$run" "factory: report your result" "say it" > /dev/null
  assert_eq "{\"dispatch\":\"$d\",\"thread\":\"thr-$d\",\"title_suffix\":\"[$d]\"}" "$(requests_of stop | jq -c .stop)" "one stop request"
  assert_eq "factory: report your result|say it" "$(requests_of send | jq -r '.send | "\(.subject)|\(.body)"')" "send request"
  : > "$REQUESTS"
  thread "$d" interrupted
  orch_worker_stop "$d" > /dev/null
  orch_worker_stop "$it.d9" > /dev/null
  assert_eq "" "$(requests_of stop)" "stop of a finished or unknown thread"
}

test_worktree_ps_shows_factory_branches_and_their_open_dispatches() {
  in_process
  run_with_intake
  bt=$(echo brief | orch_task_create "$run" build '[]' | jq -r '.result.taskId')
  orch_worktree_create app-7 "$TEST_TMP/app" origin/main app-7 7 > /dev/null
  w=$TEST_TMP/app.worktrees/app-7
  [ -d "$w" ] || fail "worktree not created at $w"
  d=$(orch_worker_start "$bt" claude sonnet "path:$w" "$run" | jq -r '.result.dispatchId')
  rows() { orch_worktree_ps | jq -c '[.result.worktrees[] | {main: .isMainWorktree, b: .branch, n: .linkedIssue, repo, a: [.agents[].mainAgent | "\(.state)/\(.outcome)"]}]'; }
  assert_eq '[{"main":true,"b":"refs/heads/main","n":null,"repo":"app","a":[]},{"main":false,"b":"refs/heads/app-7","n":7,"repo":"app","a":["unknown/null"]}]' "$(rows)" "no thread yet"
  thread "$d" running
  assert_contains "$(rows)" '"a":["running/null"]'
  thread "$d" failed
  assert_contains "$(rows)" '"a":["done/failure"]'
  # A failed build thread is the worktree row's to report, not the inbox's.
  assert_eq '[]' "$(orch_inbox "$run" | jq -c .result.messages)" "inbox for a failed build thread"
  thread "$d" completed
  assert_contains "$(rows)" '"a":["done/success"]'
  result_marker "$d" "$BUILT"
  next_process
  assert_contains "$(rows)" '"n":7,"repo":"app","a":[]'
}

test_terminal_and_automation_verbs_say_t3_has_none() {
  in_process
  assert_eq '[]' "$(orch_terminal_list "$TEST_TMP/app" | jq -c .result.terminals)" "terminals"
  orch_terminal_close term_1 > /dev/null
  if orch_terminal_create "$TEST_TMP/app" "sf-act acme/app" "true" 2> "$TEST_TMP/err"; then fail "terminal created"; fi
  assert_contains "$(cat "$TEST_TMP/err")" "T3 has no terminals"
  if orch_automation_list 2> "$TEST_TMP/err"; then fail "automations listed"; fi
  assert_contains "$(cat "$TEST_TMP/err")" "T3 scheduled task"
  if orch_automation_create factory '*/5 * * * *' p q "$TEST_TMP/app" 2> "$TEST_TMP/err"; then fail "automation created"; fi
  assert_contains "$(cat "$TEST_TMP/err")" "schedule_task"
}

test_an_unknown_factory_orch_stops_the_script() {
  st=0
  FACTORY_ORCH=nomad sh "$FACTORY_ROOT/bin/sf-state" acme/app > "$TEST_TMP/out" 2> "$TEST_TMP/err" || st=$?
  assert_eq 2 "$st" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "FACTORY_ORCH [nomad] is neither orca nor t3"
}

# ---- sf-act fire after fire on T3 (the act world's scenarios) -------------------------------------

test_t3_a_fresh_issue_gets_one_run_with_intake_and_a_dispatch_request() {
  t3_world
  acts
  assert_eq 1 "$(runs_count)" "Runs"
  assert_eq dispatched "$(status_of intake)" "intake"
  assert_eq pending "$(status_of route)" "route"
  assert_eq claude/sonnet "$(agent_of intake)" "intake agent"
  assert_eq "factory-role: intake" "$(requests_of dispatch | jq -r .dispatch.brief | head -n 1)" "brief line 1"
  # The foreman has not made the thread yet: the next fire asks again and starts nothing new.
  : > "$REQUESTS"
  acts
  assert_eq 1 "$(runs_count)" "Runs after a second fire"
  assert_eq 2 "$(t3_q '.tasks | length')" "tasks after a second fire"
  assert_eq 1 "$(requests_of dispatch | wc -l | tr -d ' ')" "dispatch requests on the second fire"
  assert_eq 1 "$(dispatch_count "$(id_of intake)")" "intake dispatches"
  no_orca_called
}

test_t3_go_builds_then_the_gate_opens_a_pr_and_review_is_dispatched() {
  t3_world
  to_review
  assert_contains "$(worktree_of build)" "app.worktrees/app-7"
  assert_eq "$(git rev-parse origin/main)" "$(git -C "$(wt_path)" rev-parse HEAD)" "branch base"
  assert_contains "$(spec_of review)" "PR #12"
  assert_eq codex/codex-auto-review "$(agent_of review)" "review agent"
  assert_eq "acme/app#7 review [$(dispatch_of review)]" "$(requests_of dispatch | jq -r 'select(.dispatch.station == "review") | .dispatch.title')" "review request"
  no_orca_called
}

test_t3_worker_stopped_without_reporting_is_nudged_once_then_stopped() {
  t3_world
  acts
  escalation intake 2026-11-03T00:00:00Z
  : > "$REQUESTS"
  acts
  d=$(dispatch_of intake)
  assert_eq "$d|factory: report your result" "$(requests_of send | jq -r '.send | "\(.dispatch)|\(.subject)"')" "nudge request"
  assert_contains "$(fake_stdin)" "\"kind\":\"nudge\",\"dispatch\":\"$d\""
  assert_eq dispatched "$(status_of intake)" "intake after the nudge"
  m=$(jq -cn --arg d "$d" '{kind: "nudge", dispatch: $d}')
  timeline "[$READY_EVENT,$(marker_comment "$m" 2026-11-03T00:01:00Z)]"
  escalation intake 2026-11-03T01:00:00Z
  acts
  assert_eq failed "$(status_of intake)" "intake"
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "worker stopped without reporting, again after a nudge"
  assert_eq 1 "$(runs_count)" "Runs"
  no_orca_called
}

test_t3_a_station_thread_that_failed_without_reporting_is_retried_once_then_stopped() {
  t3_world
  to_review
  agent_ended failed
  : > "$REQUESTS"
  acts
  assert_contains "$(fake_stdin)" "\"kind\":\"retry\",\"task\":\"$(id_of review)\""
  # The failed thread is over: no stop request, and the new dispatch starts in the same fire.
  assert_eq "" "$(requests_of stop)" "stop request"
  assert_eq 0 "$(count_calls 'sf-stop')" "sf-stop calls"
  assert_eq dispatched "$(status_of review)" "review after the retry"
  assert_eq "$(id_of review).d2" "$(requests_of dispatch | jq -r .dispatch.id)" "the new dispatch's request"
  assert_eq 2 "$(dispatch_count "$(id_of review)")" "review dispatches"
  timeline "[$READY_EVENT,$(marker_comment "$(jq -cn --arg t "$(id_of review)" '{kind: "retry", task: $t}')" 2026-11-03T00:00:00Z)]"
  thread "$(dispatch_of review)" failed 2026-11-03T00:10:00Z "Codex could not finish this response again."
  acts
  assert_eq failed "$(status_of review)" "review"
  stop=$(grep '^sf-stop' "$FAKE_LOG")
  assert_contains "$stop" "review agent ended with outcome=failure and no report, again after a retry"
  assert_contains "$stop" "Codex could not finish this response again."
  no_orca_called
}

test_t3_a_merged_runs_worktree_is_removed_with_a_cleanup_request_and_a_second_fire_does_nothing() {
  t3_world
  to_build
  w=$(wt_path)
  bd=$(dispatch_of build)
  thread "$bd" completed
  run_done
  : > "$REQUESTS"
  acts
  [ ! -d "$w" ] || fail "worktree still on disk"
  if git -C "$TEST_TMP/app" show-ref --verify -q refs/heads/app-7; then fail "branch app-7 still exists"; fi
  assert_eq "{\"repo\":\"acme/app\",\"issue\":7,\"worktree\":\"$w\",\"branch\":\"app-7\",\"threads\":[{\"dispatch\":\"$bd\",\"thread\":\"thr-$bd\"}]}" \
    "$(requests_of cleanup | jq -c .cleanup)" "cleanup request"
  : > "$REQUESTS"
  acts
  assert_eq "" "$(requests_of cleanup)" "cleanup on a second fire"
  no_orca_called
}

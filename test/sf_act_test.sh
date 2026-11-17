# shellcheck shell=sh
# shellcheck disable=SC2016 # jq programs and markdown in single quotes
# sf-act: carries out sf-state's actions, fire after fire, in the world of test/act_world.sh.

# shellcheck source=test/act_world.sh
. "$FACTORY_ROOT/test/act_world.sh"

test_a_fresh_issue_gets_an_attempt_marker_then_one_run_with_intake_and_route() {
  world
  acts
  assert_eq 1 "$(runs_count)" "Runs"
  assert_eq "factory acme/app#7" "$(sim '.runs[0].objective')" "objective"
  # The attempt marker is posted before the Run exists, so a crash between them still counts.
  first_comment=$(grep -n '^gh issue comment 7' "$FAKE_LOG" | head -n 1 | cut -d: -f1)
  run_create=$(grep -n '^orca orchestration run-create' "$FAKE_LOG" | cut -d: -f1)
  [ "$first_comment" -lt "$run_create" ] || fail "attempt comment came after run-create"
  assert_contains "$(fake_stdin)" '<!-- factory:{"kind":"attempt"} -->'
  assert_eq dispatched "$(status_of intake)" "intake"
  assert_eq pending "$(status_of route)" "route"
  assert_eq claude/sonnet "$(agent_of intake)" "intake agent"
  assert_eq "factory-role: intake" "$(spec_of intake | head -n 1)" "intake spec line 1"
  assert_eq "" "$(sim '.tasks[0].display')" "display name"
  # A second fire with the worker still busy does nothing.
  acts
  assert_eq 1 "$(runs_count)" "Runs after a second fire"
  assert_eq 2 "$(sim '.tasks | length')" "tasks after a second fire"
}

test_go_preps_a_fresh_branch_deletes_a_stale_remote_one_and_starts_build() {
  world
  git_q push origin main:app-7
  acts
  finish intake "$GO"
  acts
  assert_eq "" "$(git ls-remote origin app-7)" "stale remote app-7"
  assert_eq completed "$(status_of route)" "route"
  assert_eq dispatched "$(status_of build)" "build"
  assert_eq pending "$(status_of gate)" "gate"
  assert_eq claude/sonnet "$(agent_of build)" "build agent"
  assert_contains "$(worktree_of build)" "worktrees/app-7"
  assert_eq "$(git rev-parse origin/main)" "$(git -C "$ORCA_SIM/worktrees/app-7" rev-parse HEAD)" "branch base"
  spec=$(spec_of build)
  assert_contains "$spec" "- Branch: app-7"
  assert_contains "$spec" "- Work type: feature"
}

test_plan_first_posts_the_plan_without_its_result_line_and_the_next_fire_builds() {
  world
  acts
  finish intake "$PLAN_FIRST"
  acts
  assert_eq dispatched "$(status_of plan)" "plan"
  assert_eq claude/opus "$(agent_of plan)" "plan agent"
  assert_eq none "$(status_of build)" "build before the plan"
  finish plan "$(printf '## Plan\n1. add greet\n2. test it\nfactory-result: {"station":"plan","status":"planned"}')"
  : > "$FAKE_LOG.stdin"
  acts
  posted=$(fake_stdin)
  assert_contains "$posted" "1. add greet"
  assert_contains "$posted" "\"kind\":\"plan\",\"task\":\"$(id_of plan)\""
  case "$posted" in *factory-result:*) fail "a factory-result line was posted: $posted" ;; esac
  assert_eq completed "$(status_of post-plan)" "post-plan"
  assert_eq dispatched "$(status_of build)" "build after the plan"
  assert_contains "$(spec_of build)" "- Tier: high"
}

test_post_plan_redone_after_a_crash_posts_the_plan_once() {
  world
  acts
  finish intake "$PLAN_FIRST"
  acts
  finish plan "$(printf 'the plan\nfactory-result: {"station":"plan","status":"planned"}')"
  orca_fails create "worktree: disk full"
  act
  assert_eq 1 "$act_status" "sf-act exit status with worktree create failing"
  assert_eq ready "$(status_of post-plan)" "post-plan after the crash"
  assert_eq 1 "$(grep -c 'kind":"plan' "$FAKE_LOG.stdin")" "plan comments"
  m=$(jq -cn --arg t "$(id_of plan)" '{kind: "plan", task: $t}')
  timeline "[$READY_EVENT,$(marker_comment "$m" 2026-11-02T00:00:00Z)]"
  orca_ok create
  acts
  assert_eq 1 "$(grep -c 'kind":"plan' "$FAKE_LOG.stdin")" "plan comments after the redo"
  assert_eq dispatched "$(status_of build)" "build"
}

test_a_step_that_dies_midway_is_redone_without_doubling_tasks() {
  world
  acts
  finish intake "$GO"
  orca_fails_after task-create 1
  act
  assert_eq 1 "$act_status" "sf-act exit status"
  assert_eq ready "$(status_of route)" "route after the crash"
  assert_eq none "$(status_of gate)" "gate after the crash"
  orca_ok task-create
  acts
  assert_eq 1 "$(count_titled build)" "build tasks"
  assert_eq 1 "$(count_titled gate)" "gate tasks"
  assert_eq dispatched "$(status_of build)" "build"
  assert_eq 1 "$(runs_count)" "Runs"
}

test_gate_pass_opens_a_draft_pr_and_queues_review_verify_and_ship() {
  world
  to_review
  assert_called "gantry-gate-evidence --force-with-lease"
  assert_called "gh pr create -R acme/app --draft --head app-7 --base main --title Greet people --body-file -"
  assert_contains "$(fake_stdin)" "Closes #7"
  assert_eq completed "$(status_of gate)" "gate"
  assert_eq codex/codex-auto-review "$(agent_of review)" "review agent"
  assert_contains "$(spec_of review)" "PR #12"
  assert_eq pending "$(status_of verify)" "verify"
  assert_eq pending "$(status_of ship)" "ship"
}

test_gate_failure_gets_one_fix_round_and_a_second_failure_stops() {
  world
  to_build
  fixture gantry-gate-evidence --force-with-lease <<'EOF'
FAIL: no failing test commit
EOF
  fixture_exit 1
  finish build "$BUILT"
  acts
  assert_eq completed "$(status_of gate)" "gate"
  assert_eq dispatched "$(status_of 'build fix')" "build fix"
  assert_contains "$(spec_of 'build fix')" "## Evidence gate failure"
  assert_contains "$(spec_of 'build fix')" "FAIL: no failing test commit"
  finish 'build fix' "$BUILT"
  act
  assert_eq failed "$(status_of 'gate fix')" "gate fix"
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "evidence gate failed again after a fix"
  assert_eq none "$(status_of review)" "review"
}

test_review_without_codex_posts_not_run_and_verify_starts() {
  world
  to_build
  echo "PASS" | fixture gantry-gate-evidence --force-with-lease
  open_pr_seq app-7 '' 12
  fixture gh pr create -R "$REPO" --draft --head app-7 --base main --title "Greet people" --body-file - < /dev/null
  fixture gh pr comment 12 -R "$REPO" --body-file - < /dev/null
  orca_fails worker-start "codex: command not found"
  finish build "$BUILT"
  act
  orca_ok worker-start
  assert_contains "$(fake_stdin)" "factory: Codex review not run: codex: command not found"
  assert_eq completed "$(status_of review)" "review"
  assert_contains "$(sim '[.tasks[] | select(.title == "review")][0].result')" '"status":"not-run"'
  # verify turned ready; its start failed in the same fire (orca still failing), the next starts it.
  assert_eq ready "$(status_of verify)" "verify"
  acts
  assert_eq dispatched "$(status_of verify)" "verify"
}

test_review_at_a_codex_usage_limit_holds() {
  world
  to_build
  echo "PASS" | fixture gantry-gate-evidence --force-with-lease
  open_pr_seq app-7 '' 12
  fixture gh pr create -R "$REPO" --draft --head app-7 --base main --title "Greet people" --body-file - < /dev/null
  orca_fails worker-start "You've hit your usage limit. Try again in 3 hours."
  finish build "$BUILT"
  acts
  assert_eq failed "$(status_of review)" "review"
  assert_contains "$(grep '^sf-hold' "$FAKE_LOG")" "sf-hold --repo acme/app 7 codex "
  assert_eq 0 "$(count_calls 'sf-stop')" "sf-stop calls"
}

test_review_that_fails_to_start_otherwise_stops() {
  world
  to_build
  echo "PASS" | fixture gantry-gate-evidence --force-with-lease
  open_pr_seq app-7 '' 12
  fixture gh pr create -R "$REPO" --draft --head app-7 --base main --title "Greet people" --body-file - < /dev/null
  orca_fails worker-start "socket closed"
  finish build "$BUILT"
  act
  assert_eq failed "$(status_of review)" "review"
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "Codex review worker not started: socket closed"
}

test_review_findings_rework_in_round_two_and_a_round_two_fail_stops() {
  world
  to_review
  verify=$(id_of verify) ship=$(id_of ship)
  finish review 'factory-result: {"station":"review","status":"findings","head_sha":"abc","comment_url":"u","findings":2}' failed
  acts
  assert_eq completed "$(status_of review)" "review"
  assert_contains "$(sim '[.tasks[] | select(.title == "review")][0].result')" '"status":"reworked"'
  assert_eq completed "$(sim --arg v "$verify" '.tasks[] | select(.id == $v) | .status')" "round 1 verify"
  # Leaves first: ship is superseded before verify, so verify never turns ready on the way.
  s=$(grep -n "task-update --id $ship --status completed" "$FAKE_LOG" | cut -d: -f1)
  v=$(grep -n "task-update --id $verify --status completed" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$s" ] || [ -z "$v" ] || [ "$s" -ge "$v" ]; then fail "superseded out of order (ship line $s, verify line $v)"; fi
  assert_eq dispatched "$(status_of 'build r2')" "build r2"
  assert_contains "$(spec_of 'build r2')" "- Round: 2 of 2"
  assert_eq 0 "$(count_calls 'sf-stop')" "sf-stop calls"
  # Round 2 runs to verify, which fails: a stop.
  echo "PASS" | fixture gantry-gate-evidence --force-with-lease
  finish 'build r2' "$BUILT"
  acts
  finish 'review r2' "$CLEAN"
  acts
  finish 'verify r2' 'factory-result: {"station":"verify","status":"FAIL","verdict":"FAIL","head_sha":"abc","comment_url":"https://x/c2"}' failed
  acts
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "verify r2: FAIL in round 2 (https://x/c2)"
}

test_worker_stopped_without_reporting_is_nudged_once_then_stopped() {
  world
  acts
  escalation intake 2026-11-03T00:00:00Z
  acts
  assert_eq "dispatch:$(dispatch_of intake)" "$(sim '.sent[0].to')" "nudge target"
  assert_contains "$(fake_stdin)" "\"kind\":\"nudge\",\"dispatch\":\"$(dispatch_of intake)\""
  assert_eq dispatched "$(status_of intake)" "intake after the nudge"
  m=$(jq -cn --arg d "$(dispatch_of intake)" '{kind: "nudge", dispatch: $d}')
  timeline "[$READY_EVENT,$(marker_comment "$m" 2026-11-03T00:01:00Z)]"
  escalation intake 2026-11-03T01:00:00Z
  # GitHub fails during the stop: the task is already failed, so the next fire stops again and
  # never starts a new Run.
  echo 1 > "$TEST_TMP/sf-stop.exit"
  act
  assert_eq 1 "$act_status" "sf-act exit status with sf-stop failing"
  assert_eq failed "$(status_of intake)" "intake"
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "worker stopped without reporting, again after a nudge"
  rm "$TEST_TMP/sf-stop.exit"
  : > "$FAKE_LOG"
  acts
  assert_eq 1 "$(runs_count)" "Runs"
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "again after a nudge"
  assert_eq 1 "$(sim '.sent | length')" "nudges sent"
}

test_a_worker_stopped_at_a_usage_limit_is_held_not_nudged() {
  world
  acts
  printf 'Claude usage limit reached. Your limit will reset at 5pm.\n' > "$ORCA_SIM/terminal/$(dispatch_of intake)"
  escalation intake 2026-11-03T00:00:00Z
  acts
  assert_eq 0 "$(sim '.sent | length')" "nudges sent"
  assert_eq failed "$(status_of intake)" "intake"
  assert_contains "$(grep '^sf-hold' "$FAKE_LOG")" "sf-hold --repo acme/app 7 claude "
}

test_hold_results_hold_with_a_reset_and_stop_naming_a_dependency() {
  world
  acts
  finish intake 'factory-result: {"station":"intake","status":"hold","reason":"needs the parser","depends_on":[3]}' failed
  acts
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" 'Add a `Depends on #3` line'
  assert_eq 0 "$(count_calls 'sf-hold')" "sf-hold calls"
}

test_hold_result_with_provider_and_reset_calls_sf_hold() {
  world
  to_review
  finish review 'factory-result: {"station":"review","status":"hold","provider":"codex","reset":"2026-11-15T10:00:00Z","reason":"Codex usage limit"}' failed
  acts
  assert_called "sf-hold --repo acme/app 7 codex 2026-11-15T10:00:00Z"
  assert_eq 0 "$(count_calls 'sf-stop')" "sf-stop calls"
}

test_failed_task_without_a_result_line_stops_or_holds_at_a_limit() {
  world
  acts
  finish intake 'I gave up' failed
  acts
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "intake failed with no factory-result line"
}

test_result_naming_another_station_stops() {
  world
  acts
  finish intake 'factory-result: {"station":"build","status":"stop","reason":"x"}' failed
  acts
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "intake result names station [build]"
}

test_intake_stop_result_stops_with_its_reason() {
  world
  acts
  finish intake 'factory-result: {"station":"intake","status":"stop","reason":"no Done when"}' failed
  acts
  assert_called "sf-stop --repo acme/app 7 intake: no Done when"
}

# to_ship: review and verify pass; PR 12 is open on app-7 and the ship task is ready.
to_ship() {
  to_review
  finish review "$CLEAN"
  acts
  prs '[{"number":12,"headRefName":"app-7","isCrossRepository":false}]'
  open_pr app-7 12
}

test_merged_pr_runs_debrief_on_a_fresh_branch_then_files_lessons() {
  world
  to_ship
  echo "MERGED abc123" > "$TEST_TMP/sf-ship.out"
  finish verify "$VERIFIED"
  acts
  assert_called "sf-ship --repo acme/app 7 12"
  assert_eq completed "$(status_of ship)" "ship"
  assert_eq "MERGED abc123" "$(sim '[.tasks[] | select(.title == "ship")][0].result')" "ship result"
  assert_eq dispatched "$(status_of debrief)" "debrief"
  assert_eq claude/haiku "$(agent_of debrief)" "debrief agent"
  assert_contains "$(worktree_of debrief)" "worktrees/debrief-app-7"
  assert_contains "$(spec_of debrief)" "- Branch: debrief-app-7"
  # The merge closed the issue; lessons still run.
  issues '[]'
  prs '[]'
  echo "PASS" | fixture gantry-gate-evidence
  fixture gh pr create -R "$REPO" --head debrief-app-7 --base main --title "docs: debrief notes from #7" --body-file - < /dev/null
  printf 'friction: playbooks/old.md: already filed\n' | fixture gh issue list -R guangshinhaha/shinstack --state all --limit 1000 --json title -q '.[].title'
  fixture gh issue create -R guangshinhaha/shinstack -l friction --title "friction: playbooks/bug-fix.md: step 3 is unclear" --body-file - < /dev/null
  long=$(printf '%0700d' 0)
  finish debrief "$(printf 'notes\nfactory-result: {"station":"debrief","status":"debriefed","lessons":[{"file":"playbooks/bug-fix.md","what":"step 3 is unclear"},{"file":"playbooks/old.md","what":"already filed"},{"file":"x.md","what":"acme/app leaks"},{"file":"y.md","what":"the app repo is named"},{"file":"z.md","what":"%s"}]}' "$long")"
  acts
  assert_eq completed "$(status_of lessons)" "lessons"
  assert_called "gh pr create -R acme/app --head debrief-app-7 --base main --title docs: debrief notes from #7 --body-file -"
  assert_eq 1 "$(count_calls 'gh issue create')" "friction issues filed"
  assert_called "gh issue create -R guangshinhaha/shinstack -l friction --title friction: playbooks/bug-fix.md: step 3 is unclear --body-file -"
}

test_ship_stop_fails_the_ship_task_and_a_rebase_queues_a_new_review() {
  world
  to_ship
  echo "REREVIEW: rebased onto main" > "$TEST_TMP/sf-ship.out"
  echo 3 > "$TEST_TMP/sf-ship.exit"
  finish verify "$VERIFIED"
  acts
  assert_eq completed "$(sim '[.tasks[] | select(.title == "ship")][0].status')" "first ship"
  assert_eq 2 "$(count_titled review)" "review tasks"
  assert_eq dispatched "$(status_of review)" "second review"
  finish review "$CLEAN"
  acts
  echo "STOPPED: checks failed" > "$TEST_TMP/sf-ship.out"
  echo 1 > "$TEST_TMP/sf-ship.exit"
  finish verify "$VERIFIED"
  acts
  assert_eq failed "$(status_of ship)" "second ship"
  assert_called "sf-stop --repo acme/app 7 ship: checks failed"
}

test_lock_holds_the_pid_while_acting_and_is_removed_on_exit() {
  world
  mkdir "$TEST_TMP/lock"
  printf '#!/bin/sh\ncat "%s/lock/pid" > "%s/pid-seen"\nexec sh "%s/test/fakes/orca-sim" "$@"\n' "$TEST_TMP" "$TEST_TMP" "$FACTORY_ROOT" > "$TEST_TMP/bin/orca"
  status=0
  sh "$FACTORY_ROOT/bin/sf-act" --repo "$REPO" --lock "$TEST_TMP/lock" > /dev/null 2>&1 || status=$?
  assert_eq 0 "$status" "sf-act exit status"
  is_pid=$(cat "$TEST_TMP/pid-seen")
  case "$is_pid" in '' | *[!0-9]*) fail "no pid in the lock: [$is_pid]" ;; esac
  [ ! -e "$TEST_TMP/lock" ] || fail "lock not removed"
}

test_sf_state_failing_does_nothing() {
  world
  fixture gh issue list -R "$REPO" --state open --limit 1000 --json number,labels,body < /dev/null
  fixture_exit 1 "HTTP 502"
  act
  assert_eq 1 "$act_status" "sf-act exit status"
  assert_eq 0 "$(runs_count 2> /dev/null || echo 0)" "Runs"
}

test_missing_gantry_gates_stop_before_acting_and_release_the_lock() {
  world
  mkdir "$TEST_TMP/lock" "$TEST_TMP/nogantry"
  for t in sh jq git dirname cat mktemp rm sed; do ln -s "$(command -v "$t")" "$TEST_TMP/nogantry/$t"; done
  # PATH without the dirs holding a gantry gate, plus the tools above (in case their dir held
  # one). A bare symlink dir isn't enough on Windows: Git Bash tools need their DLLs on PATH.
  p=$TEST_TMP/nogantry
  for d in $(printf '%s\n' "$PATH" | tr ':' ' '); do
    [ -e "$d/gantry-gate-evidence" ] || [ -e "$d/gantry-verdict-check" ] || p=$p:$d
  done
  status=0
  PATH=$p "$TEST_TMP/nogantry/sh" "$FACTORY_ROOT/bin/sf-act" --repo "$REPO" --lock "$TEST_TMP/lock" 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "sf-act exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "gantry-gate-evidence not found on PATH"
  [ ! -e "$TEST_TMP/lock" ] || fail "lock kept"
  assert_eq 0 "$(count_calls 'gh ')" "gh calls"
}

# After an Orca restart a task can be ready again while its old worker session lives on (#7).
test_a_ready_task_whose_old_worker_lives_on_gets_no_second_worker() {
  world
  acts
  d=$(dispatch_of intake)
  sim_set '.dispatches |= map(if .id == $d then .liveness = "alive" else . end) | .tasks |= map(if .title == "intake" then .status = "ready" else . end)' --arg d "$d"
  act
  assert_eq 1 "$act_status" "sf-act exit status (the next fire retries)"
  assert_eq 1 "$(sim '[.dispatches[] | select(.task == $t)] | length' --arg t "$(id_of intake)")" "intake dispatches while the old worker lives"
  assert_contains "$(cat "$TEST_TMP/err")" "its last worker ($d) has not exited"
  sim_set '.dispatches |= map(if .id == $d then .liveness = "exited" else . end)' --arg d "$d"
  acts
  assert_eq 2 "$(sim '[.dispatches[] | select(.task == $t)] | length' --arg t "$(id_of intake)")" "intake dispatches once it exited"
}

test_a_restart_after_a_hold_fences_the_held_worker_first() {
  world
  acts
  d=$(dispatch_of intake)
  finish intake 'factory-result: {"station":"intake","status":"hold","provider":"claude","reset":"2026-11-01T01:00:00Z","reason":"limit"}' failed
  sim_set '.dispatches |= map(if .id == $d then .liveness = "alive" else . end)' --arg d "$d"
  acts
  m='{"kind":"hold","provider":"claude","reset":"2026-11-01T01:00:00Z"}'
  timeline "[$READY_EVENT,$(marker_comment "$m" 2026-11-01T00:30:00Z)]"
  acts
  assert_eq true "$(sim '.dispatches[] | select(.id == $d) | .stopped' --arg d "$d")" "held worker stopped"
  assert_eq dispatched "$(status_of intake)" "intake after the restart"
  assert_eq 2 "$(sim '[.dispatches[] | select(.task == $t)] | length' --arg t "$(id_of intake)")" "intake dispatches"
}

test_a_lock_claimed_by_another_sf_act_is_left_alone() {
  world
  mkdir "$TEST_TMP/lock"
  echo 999999 > "$TEST_TMP/lock/pid"
  status=0
  sh "$FACTORY_ROOT/bin/sf-act" --repo "$REPO" --lock "$TEST_TMP/lock" > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "sf-act exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "already claimed by pid 999999"
  assert_eq 999999 "$(cat "$TEST_TMP/lock/pid")" "pid in the lock"
  assert_eq 0 "$(runs_count 2> /dev/null || echo 0)" "Runs"
}

test_a_lock_taken_over_while_acting_is_not_removed_on_exit() {
  world
  mkdir "$TEST_TMP/lock"
  # A takeover mid-fire: another holder's pid replaces this sf-act's.
  printf '#!/bin/sh\necho 999999 > "%s/lock/pid"\nexec sh "%s/test/fakes/orca-sim" "$@"\n' "$TEST_TMP" "$FACTORY_ROOT" > "$TEST_TMP/bin/orca"
  sh "$FACTORY_ROOT/bin/sf-act" --repo "$REPO" --lock "$TEST_TMP/lock" > /dev/null 2>&1 || :
  [ -d "$TEST_TMP/lock" ] || fail "the new holder's lock was removed"
  assert_eq 999999 "$(cat "$TEST_TMP/lock/pid")" "pid in the lock"
}

# Seen in the e2e: a worker ends its body's only line with the result instead of a line of its own.
test_a_result_at_the_end_of_the_last_line_counts_and_is_never_posted() {
  world
  acts
  finish intake "Read the issue; it can be built. $PLAN_FIRST"
  acts
  assert_eq dispatched "$(status_of plan)" "plan"
  finish plan "$(printf '## Plan\n1. add greet, then test it. factory-result: {"station":"plan","status":"planned"}')"
  : > "$FAKE_LOG.stdin"
  acts
  posted=$(fake_stdin)
  assert_contains "$posted" "1. add greet, then test it."
  case "$posted" in *factory-result*) fail "a factory-result line was posted: $posted" ;; esac
  assert_eq dispatched "$(status_of build)" "build after the plan"
}

test_an_orca_read_failure_never_counts_as_the_old_worker_gone() {
  for cmd in dispatch-show worker-show; do
    world
    acts
    d=$(dispatch_of intake)
    sim_set '.dispatches |= map(if .id == $d then .liveness = "alive" else . end) | .tasks |= map(if .title == "intake" then .status = "ready" else . end)' --arg d "$d"
    orca_fails "$cmd"
    act
    assert_eq 1 "$act_status" "sf-act exit status with $cmd failing"
    assert_eq 1 "$(sim '[.dispatches[] | select(.task == $t)] | length' --arg t "$(id_of intake)")" "intake dispatches with $cmd failing"
    orca_ok "$cmd"
    rm -rf "${TEST_TMP:?}"/* 2> /dev/null
  done
}

# Interrogate findings (#7): every result a worker reports is checked before anything builds on it.
test_verify_never_starts_on_a_review_without_a_success_result() {
  for body in 'looks fine to me' 'factory-result: {"station":"review","status":"findings","head_sha":"abc","comment_url":"u","findings":3}'; do
    world
    to_review
    finish review "$body"
    act
    assert_eq "" "$(dispatch_of verify)" "verify dispatch after review [$body]"
    assert_eq failed "$(status_of verify)" "verify after review [$body]"
    [ "$(count_calls sf-stop)" -ge 1 ] || fail "no sf-stop after review [$body]"
    rm -rf "${TEST_TMP:?}"/* 2> /dev/null
  done
}

test_a_worker_claiming_reworked_is_refused() {
  world
  to_build
  echo "PASS: pushed app-7" | fixture gantry-gate-evidence --force-with-lease
  finish build 'factory-result: {"station":"build","status":"reworked"}'
  act
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "build worker reported sf-act's own status [reworked]"
}

# The sf-stop stub leaves the ready label, so later passes stop the dead Run again; real sf-stop
# takes the issue out of the factory. What matters: it stops, and build never starts.
test_intake_go_without_a_valid_tier_stops() {
  world
  acts
  finish intake 'factory-result: {"station":"intake","status":"go"}'
  act
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "intake go has tier []"
  assert_eq failed "$(status_of route)" "route"
  assert_eq none "$(status_of build)" "build"
}

test_a_nudge_whose_marker_fails_is_never_sent_twice() {
  world
  acts
  escalation intake 2026-11-03T00:00:00Z
  fixture gh issue comment 7 -R "$REPO" --body-file - < /dev/null
  fixture_exit 1 "gh: HTTP 502"
  act
  act
  act
  [ "$(sim '.sent | length')" -le 1 ] || fail "nudges sent: $(sim '.sent | length')"
}

test_a_merge_completes_ship_even_when_the_debrief_cannot_be_queued() {
  world
  to_review
  finish review "$CLEAN"
  acts
  prs '[{"number":12,"headRefName":"app-7","isCrossRepository":false}]'
  open_pr app-7 12
  echo "MERGED abc123" > "$TEST_TMP/sf-ship.out"
  finish verify "$VERIFIED"
  orca_fails task-create "orca: down"
  act
  assert_eq completed "$(status_of ship)" "ship"
  assert_contains "$(cat "$TEST_TMP/err")" "no debrief: not queued after the merge"
}

# Verifier finding (#7): only sf-act's Codex skip completes review as not-run.
test_a_worker_claiming_not_run_never_starts_verify() {
  world
  to_review
  finish review 'factory-result: {"station":"review","status":"not-run","head_sha":"abc","reason":"x"}'
  act
  assert_eq "" "$(dispatch_of verify)" "verify dispatch"
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "review worker reported sf-act's own status [not-run]"
}

# Verifier finding (#7): a fire that dies after the merge leaves ship ready on a closed issue; the
# next fire completes it and runs the debrief, so the Run never holds a slot for good.
test_a_ship_left_ready_after_the_merge_completes_on_the_next_fire() {
  world
  to_ship
  echo "MERGED abc123" > "$TEST_TMP/sf-ship.out"
  finish verify "$VERIFIED"
  orca_fails task-update "orca: down"
  act
  assert_eq ready "$(status_of ship)" "ship after the failed fire"
  orca_ok task-update
  rm "$TEST_TMP/sf-ship.out"
  issues '[]'
  echo 12 | fixture gh pr list -R "$REPO" --head app-7 --state merged --json number,isCrossRepository -q '[.[] | select(.isCrossRepository | not)][0].number // empty'
  acts
  assert_eq 1 "$(count_calls sf-ship)" "sf-ship calls"
  assert_eq completed "$(status_of ship)" "ship"
  assert_contains "$(sim '[.tasks[] | select(.title == "ship")][0].result')" "merged (PR #12) by an earlier fire"
  assert_eq dispatched "$(status_of debrief)" "debrief"
}

test_a_ship_left_ready_on_an_issue_closed_without_a_merge_completes_without_a_debrief() {
  world
  to_ship
  issues '[]'
  printf '\n' | fixture gh pr list -R "$REPO" --head app-7 --state merged --json number,isCrossRepository -q '[.[] | select(.isCrossRepository | not)][0].number // empty'
  finish verify "$VERIFIED"
  acts
  assert_eq 0 "$(count_calls sf-ship)" "sf-ship calls"
  assert_eq completed "$(status_of ship)" "ship"
  assert_eq none "$(status_of debrief)" "debrief"
}

# An issue closed while its Run is mid-build (by hand, or another PR's `Closes`): the Run is
# abandoned, its worker stopped and its open tasks failed, so it never holds a slot forever.
test_an_issue_closed_mid_run_abandons_the_run() {
  world
  to_build
  sim_set '.dispatches |= map(if .id == $d then .liveness = "alive" else . end)' --arg d "$(dispatch_of build)"
  issues '[]'
  acts
  assert_eq failed "$(status_of build)" "build"
  assert_eq true "$(sim --arg d "$(dispatch_of build)" '.dispatches[] | select(.id == $d) | .stopped // false')" "build worker stopped"
  assert_eq 0 "$(sim '[.tasks[] | select(.status == "ready" or .status == "dispatched" or .status == "pending")] | length')" "open tasks"
  assert_contains "$(sim '[.tasks[] | select(.title == "build")][0].result')" '"status":"stop"'
  assert_eq 0 "$(count_calls sf-stop)" "sf-stop calls"
  assert_eq '[]' "$(sh "$FACTORY_ROOT/bin/sf-state" "$REPO" | jq -c .)" "actions after the abandon"
}

# Closed between build and gate: the ready gate is abandoned, not left ready forever.
test_an_issue_closed_with_a_step_ready_abandons_the_run() {
  world
  to_build
  issues '[]'
  finish build "$BUILT"
  acts
  assert_eq failed "$(status_of gate)" "gate"
  assert_eq 0 "$(count_calls gantry-gate-evidence)" "gate runs"
  assert_eq '[]' "$(sh "$FACTORY_ROOT/bin/sf-state" "$REPO" | jq -c .)" "actions after the abandon"
}

# claude_md <text>: origin's default branch gets this CLAUDE.md.
claude_md() {
  printf '%s\n' "$1" > CLAUDE.md
  git add CLAUDE.md && git_q commit -m claude-md && git_q push origin main
}

test_a_factory_model_line_overrides_the_station_agent_and_model() {
  world
  claude_md "$(printf 'shinstack-mode: auto\nfactory-model.intake: codex/codex-auto-review\nfactory-model.build: claude/opus')"
  acts
  assert_eq codex/codex-auto-review "$(agent_of intake)" "intake agent"
  finish intake "$GO"
  acts
  assert_eq claude/opus "$(agent_of build)" "build agent"
}

test_no_factory_model_line_keeps_the_default() {
  world
  claude_md "$(printf 'shinstack-mode: auto\nfactory-model.build: claude/opus')"
  acts
  assert_eq claude/sonnet "$(agent_of intake)" "intake agent"
}

# bad_model_line <line>: the line stops the issue naming it, and no worker starts.
bad_model_line() {
  world
  claude_md "$(printf 'shinstack-mode: auto\n%s' "$1")"
  act
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "[$1]"
  assert_eq failed "$(status_of intake)" "intake"
  assert_eq 0 "$(count_calls 'orca orchestration worker-start')" "workers"
}
test_a_factory_model_line_without_a_slash_stops() { bad_model_line 'factory-model.build: opus'; }
test_a_factory_model_line_for_an_unknown_station_stops() { bad_model_line 'factory-model.deploy: claude/opus'; }
test_a_factory_model_line_for_an_unknown_agent_stops() { bad_model_line 'factory-model.build: gemini/pro'; }
test_a_factory_model_line_with_trailing_text_stops() { bad_model_line 'factory-model.build: claude/opus extra'; }

test_factory_sensitive_forces_review_onto_claude_over_any_review_line() {
  world
  claude_md "$(printf 'factory-sensitive: true\nfactory-model.review: codex/codex-auto-review')"
  to_review
  assert_eq claude/opus "$(agent_of review)" "review agent"
}

test_a_sensitive_review_that_fails_to_start_is_never_recorded_as_a_codex_not_run() {
  world
  claude_md "$(printf 'factory-sensitive: true')"
  to_build
  echo "PASS" | fixture gantry-gate-evidence --force-with-lease
  open_pr_seq app-7 '' 12
  fixture gh pr create -R "$REPO" --draft --head app-7 --base main --title "Greet people" --body-file - < /dev/null
  orca_fails worker-start "claude: not logged in"
  finish build "$BUILT"
  act
  assert_eq ready "$(status_of review)" "review"
  assert_eq 0 "$(count_calls 'gh pr comment')" "not-run comments"
}

test_a_hold_names_the_provider_the_worker_was_launched_on() {
  world
  claude_md "$(printf 'factory-model.intake: codex/gpt')"
  orca_fails worker-start "codex usage limit reached"
  act
  assert_contains "$(grep '^sf-hold' "$FAKE_LOG")" " codex "
}

test_a_malformed_factory_sensitive_line_stops_naming_the_line() {
  world
  claude_md "$(printf 'factory-sensitive: true # PDPA')"
  act
  assert_contains "$(grep '^sf-stop' "$FAKE_LOG")" "[factory-sensitive: true # PDPA]"
  assert_eq 0 "$(count_calls 'orca orchestration worker-start')" "workers"
}

test_an_override_pushed_to_origin_since_the_last_fetch_applies() {
  world
  git_q clone "$TEST_TMP/origin.git" "$TEST_TMP/other"
  printf 'factory-model.intake: claude/opus\n' > "$TEST_TMP/other/CLAUDE.md"
  git -C "$TEST_TMP/other" add CLAUDE.md
  git -C "$TEST_TMP/other" commit -q -m override
  git -C "$TEST_TMP/other" push -q origin HEAD:main
  acts
  assert_eq claude/opus "$(agent_of intake)" "intake agent"
}

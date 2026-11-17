# shellcheck shell=sh
# sf-state: the next actions, computed from GitHub (fake gh) and Orca (fake orca).
# Each test builds its world inline with the helpers below. The repo is acme/app.

REPO=acme/app

# fixture <tool> <args...>: stdin becomes the fake's stdout for exactly those args.
fixture() {
  tool=$1
  shift
  key=$(sh "$FACTORY_ROOT/test/fakes/fake-cli" --key "$@")
  mkdir -p "$FAKE_FIXTURES/$tool"
  cat > "$FAKE_FIXTURES/$tool/$key.out"
}

# fixture_fail <tool> <args...>: the call fails with status 1 and a message.
fixture_fail() {
  fixture "$@" < /dev/null
  echo 1 > "$FAKE_FIXTURES/$tool/$key.exit"
  echo "HTTP 502: Bad Gateway" > "$FAKE_FIXTURES/$tool/$key.err"
}

# An empty world: no issues, no Runs, no PRs, factory-concurrency 2.
world() {
  FAKE_FIXTURES=$TEST_TMP/fx
  export FAKE_FIXTURES
  mkdir -p "$FAKE_FIXTURES"
  cd "$TEST_TMP" || fail "test dir not entered: $TEST_TMP"
  printf '# app\n\nshinstack-mode: auto\nfactory-concurrency: 2\n' > CLAUDE.md
  issues '[]'
  runs '[]'
  prs '[]'
}

issues() { printf '%s\n' "$1" | fixture gh issue list -R "$REPO" --state open --limit 1000 --json number,labels,body; }
# prs <json>: open PRs; a PR without isCrossRepository is from the repo itself (false).
prs() { printf '%s\n' "$1" | jq -c 'map(if type == "object" and (has("isCrossRepository") | not) then . + {isCrossRepository: false} else . end)' | prs_raw; }
prs_raw() { fixture gh pr list -R "$REPO" --state open --limit 1000 --json number,headRefName,isCrossRepository; }
runs() { printf '{"ok":true,"result":{"runs":%s,"nextCursor":null}}\n' "$1" | fixture orca orchestration run-list --json --full --limit 100; }
# tasks <run> <json>: the Run's tasks, and an empty inbox (inbox_of sets escalations).
tasks() {
  printf '{"ok":true,"result":{"tasks":%s,"runId":"%s"}}\n' "$2" "$1" | fixture orca orchestration task-list --run "$1" --json
  inbox_of "$1" '[]'
}
inbox_of() { printf '{"ok":true,"result":{"messages":%s,"count":0}}\n' "$2" | fixture orca orchestration inbox --terminal "run:$1" --limit 500 --json --full; }
# escalation <task> <dispatch> <created_at>: Orca's "stopped without reporting" message.
escalation() {
  jq -cn --arg t "$1" --arg d "$2" --arg at "$3" \
    '{type: "escalation", subject: "Worker stopped without reporting", payload: ({taskId: $t, dispatchId: $d, stopReason: "finished"} | tojson), created_at: $at}'
}
timeline() { printf '%s\n' "$2" | fixture gh api "repos/$REPO/issues/$1/timeline" --paginate; }

# ready_issue <n> [body]: an open issue labelled ready, readied at 2026-11-01, no comments.
ready_issue_json() { printf '{"number":%s,"labels":[{"name":"ready"}],"body":"%s"}' "$1" "${2:-}"; }
readied() { timeline "$1" '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"}]'; }

# run_json <id> <issue> [created_at] [repo]
run_json() { printf '{"id":"%s","objective":"factory %s#%s","created_at":"%s"}' "$1" "${4:-$REPO}" "$2" "${3:-2026-11-02T00:00:00Z}"; }

attempt='<!-- factory:{\"kind\":\"attempt\"} -->'
comment() { printf '{"event":"commented","author_association":"OWNER","body":"%s","created_at":"%s"}' "$1" "$2"; }

sf_state() { sh "$FACTORY_ROOT/bin/sf-state" "$@"; }
state() { sf_state "$REPO"; }

test_fresh_ready_issue_starts() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  assert_eq '[{"action":"start","issue":7}]' "$(state)" "actions"
}

test_non_ready_issues_are_ignored() {
  world
  issues '[{"number":1,"labels":[],"body":""},{"number":2,"labels":[{"name":"needs-shin"}],"body":""},{"number":3,"labels":[{"name":"icebox"}],"body":""},{"number":4,"labels":[{"name":"ready"},{"name":"needs-shin"}],"body":""}]'
  assert_eq '[]' "$(state)" "actions"
}

test_live_run_with_dispatched_task_needs_nothing() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"build"},{"id":"t2","status":"pending","title":"review","deps":"[\"t1\"]"}]'
  assert_eq '[]' "$(state)" "actions"
}

test_live_run_with_ready_task_advances() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"completed","title":"build"},{"id":"t2","status":"ready","title":"review"}]'
  assert_eq '[{"action":"advance","issue":7,"run":"run_a","task":"t2"}]' "$(state)" "actions"
}

test_ready_ship_task_ships_the_pr_found_by_branch() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"completed","title":"build"},{"id":"t9","status":"ready","title":"ship"}]'
  prs '[{"number":40,"headRefName":"someone/app-17-other"},{"number":41,"headRefName":"someone/app-7-add-login"}]'
  assert_eq '[{"action":"ship","issue":7,"run":"run_a","task":"t9","pr":41}]' "$(state)" "actions"
}

test_fork_pr_on_a_factory_branch_is_never_shipped() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t9","status":"ready","title":"ship"}]'
  prs '[{"number":66,"headRefName":"app-7-add-login","isCrossRepository":true}]'
  assert_eq '[{"action":"stop","issue":7,"reason":"ship task ready but no open PR on a branch named app-7-*"}]' "$(state)" "actions"
}

test_same_repo_pr_ships_even_when_a_fork_pr_matches_first() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t9","status":"ready","title":"ship"}]'
  prs '[{"number":66,"headRefName":"app-7-evil","isCrossRepository":true},{"number":41,"headRefName":"someone/app-7-add-login","isCrossRepository":false}]'
  assert_eq '[{"action":"ship","issue":7,"run":"run_a","task":"t9","pr":41}]' "$(state)" "actions"
}

test_ready_ship_task_with_no_pr_owes_a_stop() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t9","status":"ready","title":"ship"}]'
  prs '[{"number":40,"headRefName":"someone/app-70-x"}]'
  assert_eq '[{"action":"stop","issue":7,"reason":"ship task ready but no open PR on a branch named app-7-*"}]' "$(state)" "actions"
}

test_dead_run_without_hold_owes_a_stop_and_is_never_started() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"failed","title":"build"},{"id":"t2","status":"pending","title":"review"}]'
  assert_eq '[{"action":"stop","issue":7,"reason":"run run_a task build failed","run":"run_a","task":"t1"}]' "$(state)" "actions"
}

test_dead_run_with_no_tasks_is_skipped_and_the_issue_starts_again() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[]'
  assert_eq '[{"action":"start","issue":7}]' "$(state)" "actions"
}

test_dead_run_with_expired_hold_restarts_the_failed_task() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(comment "$attempt" 2026-11-01T00:01:00Z),$(comment '<!-- factory:{\"kind\":\"hold\",\"provider\":\"claude\",\"reset\":\"2001-01-01T00:00:00Z\"} -->' 2026-11-01T01:00:00Z)]"
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"completed","title":"build"},{"id":"t2","status":"failed","title":"review"}]'
  assert_eq '[{"action":"restart","issue":7,"run":"run_a","task":"t2"}]' "$(state)" "actions"
}

test_hold_consumed_by_a_restart_no_longer_applies() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(comment '<!-- factory:{\"kind\":\"hold\",\"provider\":\"claude\",\"reset\":\"2001-01-01T00:00:00Z\"} -->' 2026-11-01T01:00:00Z),$(comment '<!-- factory:{\"kind\":\"restart\"} -->' 2026-11-01T02:00:00Z)]"
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t2","status":"failed","title":"review"}]'
  assert_eq '[{"action":"stop","issue":7,"reason":"run run_a task review failed","run":"run_a","task":"t2"}]' "$(state)" "actions"
}

test_unexpired_hold_waits_and_blocks_every_start_in_the_repo() {
  world
  issues "[$(ready_issue_json 7),$(ready_issue_json 8)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(comment '<!-- factory:{\"kind\":\"hold\",\"provider\":\"codex\",\"reset\":\"2099-01-01T00:00:00Z\"} -->' 2026-11-01T01:00:00Z)]"
  readied 8
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t2","status":"failed","title":"review"}]'
  assert_eq '[]' "$(state)" "actions"
}

test_three_attempts_since_ready_owes_a_stop() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(comment "$attempt" 2026-11-02T00:00:00Z),$(comment "$attempt" 2026-11-03T00:00:00Z),$(comment "$attempt" 2026-11-04T00:00:00Z)]"
  assert_eq '[{"action":"stop","issue":7,"reason":"3 attempts since it was last labelled ready"}]' "$(state)" "actions"
}

# Re-readying resets the count, and a dead Run from before the re-ready is history, not a stop.
test_re_readied_issue_after_three_attempts_gets_a_fresh_count() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(comment "$attempt" 2026-11-02T00:00:00Z),$(comment "$attempt" 2026-11-03T00:00:00Z),$(comment "$attempt" 2026-11-04T00:00:00Z),{\"event\":\"unlabeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-05T00:00:00Z\"},{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-06T00:00:00Z\"}]"
  runs "[$(run_json run_old 7 2026-11-04T00:00:00Z)]"
  tasks run_old '[{"id":"t1","status":"failed","title":"build"}]'
  assert_eq '[{"action":"start","issue":7}]' "$(state)" "actions"
}

test_concurrency_full_starts_nothing() {
  world
  issues "[$(ready_issue_json 5),$(ready_issue_json 6),$(ready_issue_json 7)]"
  readied 5
  readied 6
  readied 7
  runs "[$(run_json run_a 5),$(run_json run_b 6)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"build"}]'
  tasks run_b '[{"id":"t1","status":"dispatched","title":"build"}]'
  assert_eq '[]' "$(state)" "actions"
}

test_starts_oldest_issues_up_to_factory_concurrency() {
  world
  printf 'factory-concurrency: 1\n' > CLAUDE.md
  issues "[$(ready_issue_json 9),$(ready_issue_json 4)]"
  readied 9
  readied 4
  assert_eq '[{"action":"start","issue":4}]' "$(state)" "actions"
}

test_concurrency_defaults_to_two_without_the_claude_md_line() {
  world
  printf '# app\n' > CLAUDE.md
  issues "[$(ready_issue_json 1),$(ready_issue_json 2),$(ready_issue_json 3)]"
  readied 1
  readied 2
  readied 3
  assert_eq '[{"action":"start","issue":1},{"action":"start","issue":2}]' "$(state)" "actions"
}

test_host_wide_cap_reached_by_other_repos_starts_nothing() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_1 1 2026-11-02T00:00:00Z acme/one),$(run_json run_2 2 2026-11-02T00:00:00Z acme/two),$(run_json run_3 3 2026-11-02T00:00:00Z beta/three),{\"id\":\"run_x\",\"objective\":\"shinfactory stages for app\",\"created_at\":\"2026-11-02T00:00:00Z\"}]"
  for r in run_1 run_2 run_3; do tasks "$r" '[{"id":"t1","status":"dispatched","title":"build"}]'; done
  status=0
  out=$(FACTORY_MAX_RUNS=3 sf_state "$REPO") || status=$?
  assert_eq 0 "$status" "exit status"
  assert_eq '[]' "$out" "actions"
  assert_not_called "orca orchestration task-list --run run_x --json"
}

test_host_wide_cap_defaults_to_four() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_1 1 2026-11-02T00:00:00Z acme/one),$(run_json run_2 2 2026-11-02T00:00:00Z acme/two),$(run_json run_3 3 2026-11-02T00:00:00Z beta/three)]"
  for r in run_1 run_2 run_3; do tasks "$r" '[{"id":"t1","status":"dispatched","title":"build"}]'; done
  assert_eq '[{"action":"start","issue":7}]' "$(state)" "actions with 3 of 4 slots used"
}

test_open_dependency_holds_instead_of_starting() {
  world
  issues "[$(ready_issue_json 7 'Goal\n\n## Depends on\n#3, acme/other#5\n\nParent: #11'),{\"number\":3,\"labels\":[],\"body\":\"\"},{\"number\":11,\"labels\":[],\"body\":\"\"}]"
  readied 7
  assert_eq '[{"action":"hold","issue":7,"reason":"depends on open #3"}]' "$(state)" "actions"
}

test_inline_depends_on_with_closed_issue_starts() {
  world
  issues "[$(ready_issue_json 7 'Depends on #3 and #4')]"
  readied 7
  assert_eq '[{"action":"start","issue":7}]' "$(state)" "actions"
}

test_paginates_run_list() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  printf '{"ok":true,"result":{"runs":[%s],"nextCursor":"c2"}}\n' "$(run_json run_1 1 2026-11-02T00:00:00Z acme/one)" \
    | fixture orca orchestration run-list --json --full --limit 100
  printf '{"ok":true,"result":{"runs":[%s]}}\n' "$(run_json run_2 2 2026-11-02T00:00:00Z acme/two)" \
    | fixture orca orchestration run-list --json --full --limit 100 --cursor c2
  for r in run_1 run_2; do tasks "$r" '[{"id":"t1","status":"dispatched","title":"build"}]'; done
  out=$(FACTORY_MAX_RUNS=2 sf_state "$REPO")
  assert_eq '[]' "$out" "actions"
  assert_called "orca orchestration task-list --run run_2 --json"
}

test_never_calls_the_search_api() {
  world
  issues "[$(ready_issue_json 7),$(ready_issue_json 8)]"
  readied 7
  readied 8
  runs "[$(run_json run_a 8)]"
  tasks run_a '[{"id":"t9","status":"ready","title":"ship"}]'
  prs '[{"number":41,"headRefName":"x/app-8-y"}]'
  state > /dev/null
  assert_called "gh issue list -R $REPO --state open --limit 1000 --json number,labels,body"
  if grep -Eq -- '--label|--search|search/' "$FAKE_LOG"; then
    fail "search API reached: $(cat "$FAKE_LOG")"
  fi
}

test_gh_failure_prints_no_actions_and_exits_non_zero() {
  world
  fixture_fail gh issue list -R "$REPO" --state open --limit 1000 --json number,labels,body
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "sf-state: open issues not listed" "stderr"
}

test_orca_failure_prints_no_actions_and_exits_non_zero() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  fixture_fail orca orchestration run-list --json --full --limit 100
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "sf-state: Orca Runs not listed" "stderr"
}

test_bad_concurrency_value_is_an_error() {
  world
  printf 'factory-concurrency: two\n' > CLAUDE.md
  status=0
  sf_state "$REPO" > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "factory-concurrency in CLAUDE.md is not a whole number" "stderr"
}

# Review findings on PR #16.

test_live_run_from_before_a_re_ready_is_still_the_current_run() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-06T00:00:00Z"}]'
  runs "[$(run_json run_a 7 2026-11-02T00:00:00Z)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"build"}]'
  assert_eq '[]' "$(state)" "actions"
}

test_restart_takes_a_concurrency_slot() {
  world
  issues "[$(ready_issue_json 5),$(ready_issue_json 6),$(ready_issue_json 7)]"
  readied 5
  timeline 6 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(comment '<!-- factory:{\"kind\":\"hold\",\"provider\":\"claude\",\"reset\":\"2001-01-01T00:00:00Z\"} -->' 2026-11-01T01:00:00Z)]"
  readied 7
  runs "[$(run_json run_a 5),$(run_json run_b 6)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"build"}]'
  tasks run_b '[{"id":"t2","status":"failed","title":"build"}]'
  assert_eq '[{"action":"restart","issue":6,"run":"run_b","task":"t2"}]' "$(state)" "actions"
}

test_timeline_that_is_not_a_json_array_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  printf '' | fixture gh api "repos/$REPO/issues/7/timeline" --paginate
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "sf-state: timeline of #7 not read" "stderr"
}

test_markers_from_non_collaborators_are_ignored() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},{\"event\":\"commented\",\"author_association\":\"NONE\",\"body\":\"<!-- factory:{\\\"kind\\\":\\\"hold\\\",\\\"reset\\\":\\\"2099-01-01T00:00:00Z\\\"} -->\",\"created_at\":\"2026-11-02T00:00:00Z\"}]"
  assert_eq '[{"action":"start","issue":7}]' "$(state)" "actions"
}

test_hold_without_a_valid_utc_reset_is_ignored() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(comment '<!-- factory:{\"kind\":\"hold\"} -->' 2026-11-02T00:00:00Z),$(comment '<!-- factory:{\"kind\":\"hold\",\"reset\":\"soon\"} -->' 2026-11-02T00:01:00Z)]"
  assert_eq '[{"action":"start","issue":7}]' "$(state)" "actions"
}

test_dependency_list_forms_hold() {
  world
  issues "[$(ready_issue_json 1 'Depends on:\n- #3'),$(ready_issue_json 2 '## Depends on #3'),$(ready_issue_json 4 '## Depends on\n1. #3'),$(ready_issue_json 5 '## Depends on\n- [ ] #3'),$(ready_issue_json 6 '**Depends on** #3'),{\"number\":3,\"labels\":[],\"body\":\"\"}]"
  for n in 1 2 4 5 6; do readied "$n"; done
  assert_eq '[{"action":"hold","issue":1,"reason":"depends on open #3"},{"action":"hold","issue":2,"reason":"depends on open #3"},{"action":"hold","issue":4,"reason":"depends on open #3"},{"action":"hold","issue":5,"reason":"depends on open #3"},{"action":"hold","issue":6,"reason":"depends on open #3"}]' "$(state)" "actions"
}

test_new_run_with_no_tasks_yet_is_live() {
  world
  printf 'factory-concurrency: 1\n' > CLAUDE.md
  issues "[$(ready_issue_json 7),$(ready_issue_json 8)]"
  readied 7
  readied 8
  runs "[$(run_json run_a 7 2099-01-01T00:00:00Z)]"
  tasks run_a '[]'
  assert_eq '[]' "$(state)" "actions"
}

test_starts_the_issue_readied_first() {
  world
  printf 'factory-concurrency: 1\n' > CLAUDE.md
  issues "[$(ready_issue_json 4),$(ready_issue_json 9)]"
  timeline 4 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-05T00:00:00Z"}]'
  timeline 9 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"}]'
  assert_eq '[{"action":"start","issue":9}]' "$(state)" "actions"
}

# Codex review findings, issue #18.

# 1: an older live Run is still the current Run when a newer one is done.
test_older_live_run_wins_over_a_newer_done_run() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-06T00:00:00Z"}]'
  runs "[$(run_json run_live 7 2026-11-02T00:00:00Z),$(run_json run_done 7 2026-11-03T00:00:00Z)]"
  tasks run_live '[{"id":"t1","status":"completed","title":"build"},{"id":"t2","status":"ready","title":"review"}]'
  tasks run_done '[{"id":"t1","status":"completed","title":"build"}]'
  assert_eq '[{"action":"advance","issue":7,"run":"run_live","task":"t2"}]' "$(state)" "actions"
}

# 2: fractional seconds in created_at parse; a created_at that does not parse is an error.
test_run_created_at_with_fractional_seconds_parses() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7 2099-01-01T00:00:00.123Z)]"
  tasks run_a '[]'
  assert_eq '[]' "$(state)" "actions"
}

test_run_created_at_that_does_not_parse_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7 yesterday)]"
  tasks run_a '[]'
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "Run run_a created_at [yesterday] is not a UTC ISO-8601 time" "stderr"
}

# 3: a dead Run on an open issue that is no longer ready still owes its stop, once.
test_dead_run_on_unreadied_issue_owes_a_stop() {
  world
  issues '[{"number":7,"labels":[],"body":""}]'
  timeline 7 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"},{"event":"unlabeled","label":{"name":"ready"},"created_at":"2026-11-03T00:00:00Z"}]'
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"failed","title":"build"}]'
  assert_eq '[{"action":"stop","issue":7,"reason":"run run_a task build failed","run":"run_a","task":"t1"}]' "$(state)" "actions"
}

test_dead_run_already_stopped_owes_nothing_after_needs_shin_is_removed() {
  world
  issues '[{"number":7,"labels":[],"body":""}]'
  timeline 7 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"},{"event":"unlabeled","label":{"name":"ready"},"created_at":"2026-11-03T00:00:00Z"},{"event":"labeled","label":{"name":"needs-shin"},"created_at":"2026-11-03T00:00:00Z"},{"event":"unlabeled","label":{"name":"needs-shin"},"created_at":"2026-11-04T00:00:00Z"}]'
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"failed","title":"build"}]'
  assert_eq '[]' "$(state)" "actions"
}

test_dead_run_on_needs_shin_or_icebox_issue_owes_nothing() {
  world
  issues '[{"number":7,"labels":[{"name":"needs-shin"}],"body":""},{"number":8,"labels":[{"name":"icebox"}],"body":""}]'
  runs "[$(run_json run_a 7),$(run_json run_b 8)]"
  tasks run_a '[{"id":"t1","status":"failed","title":"build"}]'
  tasks run_b '[{"id":"t1","status":"failed","title":"build"}]'
  assert_eq '[]' "$(state)" "actions"
}

# 4: a ready issue whose timeline has no ready label event has no attempt boundary.
test_timeline_without_a_ready_label_event_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 '[]'
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "sf-state: timeline of #7 has no ready label event" "stderr"
}

# 5: malformed Orca JSON fails closed instead of looking like no Runs.
test_run_list_with_null_runs_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  printf '{"ok":true,"result":{"runs":null}}\n' | fixture orca orchestration run-list --json --full --limit 100
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "sf-state: Orca Runs not listed" "stderr"
}

test_task_list_with_null_tasks_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  printf '{"ok":true,"result":{"tasks":null}}\n' | fixture orca orchestration task-list --run run_a --json
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "sf-state: tasks of Run run_a not listed" "stderr"
}

# Interrogate findings on the #18 fix: created_at is checked on every Run, not only empty ones.
bad_created_at_fails() {
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "sf-state: actions not computed: Run run_a created_at [$1] is not a UTC ISO-8601 time" "stderr"
}

test_run_with_tasks_and_no_created_at_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs '[{"id":"run_a","objective":"factory acme/app#7"}]'
  tasks run_a '[{"id":"t1","status":"failed","title":"build"}]'
  bad_created_at_fails ''
}

test_run_with_tasks_and_unparseable_created_at_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7 yesterday)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"build"}]'
  bad_created_at_fails yesterday
}

test_run_created_at_with_an_offset_is_an_error() {
  world
  issues '[{"number":7,"labels":[],"body":""}]'
  timeline 7 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"},{"event":"labeled","label":{"name":"needs-shin"},"created_at":"2026-11-03T05:00:00Z"},{"event":"unlabeled","label":{"name":"needs-shin"},"created_at":"2026-11-04T00:00:00Z"}]'
  runs "[$(run_json run_a 7 2026-11-03T08:00:00+08:00)]"
  tasks run_a '[{"id":"t1","status":"failed","title":"build"}]'
  bad_created_at_fails 2026-11-03T08:00:00+08:00
}

# A non-ready issue has no history cut-off: its newest Run is current until needs-shin follows it.
test_unreadied_issue_dead_run_from_before_a_re_ready_owes_a_stop() {
  world
  issues '[{"number":7,"labels":[],"body":""}]'
  timeline 7 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"},{"event":"unlabeled","label":{"name":"ready"},"created_at":"2026-11-03T00:00:00Z"},{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-04T00:00:00Z"},{"event":"unlabeled","label":{"name":"ready"},"created_at":"2026-11-05T00:00:00Z"}]'
  runs "[$(run_json run_a 7 2026-11-02T00:00:00Z)]"
  tasks run_a '[{"id":"t1","status":"failed","title":"build"}]'
  assert_eq '[{"action":"stop","issue":7,"reason":"run run_a task build failed","run":"run_a","task":"t1"}]' "$(state)" "actions"
}

# fails_with <stderr text>: sf-state exits 1, prints nothing on stdout, and says why.
fails_with() {
  status=0
  out=$(sf_state "$REPO" 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq '' "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "$1" "stderr"
}

test_task_without_an_id_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"status":"ready","title":"review"},null]'
  fails_with "sf-state: tasks of Run run_a not listed"
}

test_pr_without_a_number_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t9","status":"ready","title":"ship"}]'
  prs '[{"headRefName":"someone/app-7-x"}]'
  fails_with "sf-state: open PRs not listed"
}

test_pr_without_a_cross_repository_flag_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t9","status":"ready","title":"ship"}]'
  echo '[{"number":41,"headRefName":"someone/app-7-x"}]' | prs_raw
  fails_with "sf-state: open PRs not listed"
}

test_ready_label_event_without_a_time_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"}},$(comment "$attempt" 2026-10-01T00:00:00Z)]"
  fails_with "sf-state: timeline of #7 has a label event with no UTC time"
}

test_run_list_repeating_its_cursor_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  printf '{"ok":true,"result":{"runs":[],"nextCursor":"c2"}}\n' | fixture orca orchestration run-list --json --full --limit 100
  printf '{"ok":true,"result":{"runs":[],"nextCursor":"c2"}}\n' | fixture orca orchestration run-list --json --full --limit 100 --cursor c2
  fails_with "sf-state: Orca Runs not listed: run-list repeated cursor [c2]"
}

# 31: each read is checked whole. A wrong-shaped document before a valid one fails closed,
# instead of the shape check seeing only the last document.
test_issue_list_with_a_bad_document_before_a_good_one_is_an_error() {
  world
  printf '{"message":"Bad credentials"}\n[%s]\n' "$(ready_issue_json 7)" | fixture gh issue list -R "$REPO" --state open --limit 1000 --json number,labels,body
  readied 7
  fails_with "sf-state: open issues not listed: gh issue list printed"
}

test_pr_list_with_a_bad_document_before_a_good_one_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  printf '{"message":"Bad credentials"}\n[]\n' | prs_raw
  fails_with "sf-state: open PRs not listed: gh pr list printed"
}

test_run_list_with_a_bad_document_before_a_good_one_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  printf '{"ok":false,"result":{"runs":[]}}\n{"ok":true,"result":{"runs":[],"nextCursor":null}}\n' | fixture orca orchestration run-list --json --full --limit 100
  fails_with "sf-state: Orca Runs not listed"
}

test_task_list_with_a_bad_document_before_a_good_one_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  printf '{"ok":false,"result":{"tasks":[]}}\n{"ok":true,"result":{"tasks":[{"id":"t1","status":"dispatched","title":"build"}]}}\n' | fixture orca orchestration task-list --run run_a --json
  fails_with "sf-state: tasks of Run run_a not listed"
}

nudge_marker() { comment "<!-- factory:{\\\"kind\\\":\\\"nudge\\\",\\\"dispatch\\\":\\\"$1\\\"} -->" "$2"; }

test_worker_stopped_without_reporting_is_nudged_once() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"verify"}]'
  inbox_of run_a "[$(escalation t1 ctx_1 2026-11-02T01:00:00Z),$(escalation t9 ctx_9 2026-11-02T01:00:00Z)]"
  assert_eq '[{"action":"nudge","issue":7,"run":"run_a","task":"t1","dispatch":"ctx_1"}]' "$(state)" "actions"
}

test_nudged_worker_that_has_not_stopped_again_needs_nothing() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(nudge_marker ctx_1 2026-11-02T01:05:00Z)]"
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"verify"}]'
  inbox_of run_a "[$(escalation t1 ctx_1 2026-11-02T01:00:00Z)]"
  assert_eq '[]' "$(state)" "actions"
}

test_worker_stopped_again_after_a_nudge_owes_a_stop() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(nudge_marker ctx_1 2026-11-02T01:05:00Z)]"
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"verify"}]'
  inbox_of run_a "[$(escalation t1 ctx_1 2026-11-02T01:00:00Z),$(escalation t1 ctx_1 2026-11-02T01:10:00Z)]"
  assert_eq '[{"action":"stop","issue":7,"run":"run_a","task":"t1","dispatch":"ctx_1","reason":"verify worker stopped without reporting, again after a nudge"}]' "$(state)" "actions"
}

test_a_new_dispatch_of_the_task_gets_its_own_nudge() {
  world
  issues "[$(ready_issue_json 7)]"
  timeline 7 "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-01T00:00:00Z\"},$(nudge_marker ctx_1 2026-11-02T01:05:00Z)]"
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"verify"}]'
  inbox_of run_a "[$(escalation t1 ctx_1 2026-11-02T01:00:00Z),$(escalation t1 ctx_2 2026-11-02T02:00:00Z)]"
  assert_eq '[{"action":"nudge","issue":7,"run":"run_a","task":"t1","dispatch":"ctx_2"}]' "$(state)" "actions"
}

test_failed_inbox_read_is_an_error() {
  world
  issues "[$(ready_issue_json 7)]"
  readied 7
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"dispatched","title":"verify"}]'
  fixture orca orchestration inbox --terminal run:run_a --limit 500 --json --full < /dev/null
  fixture_exit 1 "boom"
  status=0
  out=$(state 2> "$TEST_TMP/err") || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq "" "$out" "stdout"
  assert_contains "$(cat "$TEST_TMP/err")" "inbox of Run run_a not read" "stderr"
}

test_closed_issue_live_run_advances_only_debrief_and_lessons() {
  world
  issues '[]'
  runs "[$(run_json run_a 7),$(run_json run_b 8)]"
  tasks run_a '[{"id":"t1","status":"completed","title":"ship"},{"id":"t2","status":"ready","title":"debrief"}]'
  tasks run_b '[{"id":"t1","status":"ready","title":"review"}]'
  assert_eq '[{"action":"advance","issue":7,"run":"run_a","task":"t2"}]' "$(state)" "actions"
}

test_closed_issue_live_run_finishes_a_ready_ship() {
  world
  issues '[]'
  runs "[$(run_json run_a 7)]"
  tasks run_a '[{"id":"t1","status":"completed","title":"verify"},{"id":"t2","status":"ready","title":"ship"}]'
  assert_eq '[{"action":"advance","issue":7,"run":"run_a","task":"t2"}]' "$(state)" "actions"
}

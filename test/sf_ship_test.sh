# shellcheck shell=sh
# sf-ship: gates, mode, check wait, rebase once, merge with --match-head-commit, and stop.
# Each test builds a real git checkout (origin is a local bare repo) on branch app-7 for PR #9 of
# issue #7; gh and the gantry gates are fakes. Repo acme/app.

REPO=acme/app
READIED='{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"}'
PR_FIELDS=state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,mergeCommit

git_q() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@" > /dev/null 2>&1; }

# commit <file> <text>: write and commit a file in the current checkout.
commit() {
  printf '%s\n' "$2" > "$1"
  git add "$1" && git_q commit -m "change $1"
}

# world [mode]: origin/main's CLAUDE.md declares shinstack-mode <mode> (default auto); the
# checkout is on app-7, one commit ahead and pushed; PR #9 is a green draft; issue #7 is ready.
world() {
  FAKE_FIXTURES=$TEST_TMP/fx
  SF_SHIP_POLL=0
  export FAKE_FIXTURES SF_SHIP_POLL
  git_q init --bare "$TEST_TMP/origin.git"
  git -C "$TEST_TMP/origin.git" symbolic-ref HEAD refs/heads/main
  git_q clone "$TEST_TMP/origin.git" "$TEST_TMP/app"
  cd "$TEST_TMP/app" || fail "checkout not entered"
  git config user.email test@example.com
  git config user.name test
  git_q checkout -b main
  printf '# app\n\nshinstack-mode: %s\n' "${1:-auto}" > CLAUDE.md
  git add CLAUDE.md && git_q commit -m init
  commit shared.txt base
  git_q push origin main
  git_q checkout -b app-7
  commit feature.txt feature
  git_q push -u origin app-7
  HEAD_SHA=$(git rev-parse HEAD)

  pr OPEN true MERGEABLE CLEAN
  echo ready | fixture gh issue view 7 -R "$REPO" --json labels -q '[.labels[].name] | join(",")'
  echo "PASS: pushed app-7" | fixture gantry-gate-evidence
  echo "PASS: verdict at head" | fixture gantry-verdict-check --pr 9 --repo "$REPO" --no-label
  reviewed "$(review_comment OWNER "$HEAD_SHA")"
  fixture gh pr ready 9 -R "$REPO" < /dev/null
  checks '[{"name":"gantry / ci-ok","bucket":"pass"}]'
  fixture gh pr merge 9 -R "$REPO" --squash --match-head-commit "$HEAD_SHA" < /dev/null
  # sf-stop's calls, for tests that stop.
  timeline "[$READIED]"
  echo https://github.com/acme/app/issues/7#c1 | fixture gh issue comment 7 -R "$REPO" --body-file -
  fixture gh issue edit 7 -R "$REPO" --add-label needs-shin --remove-label ready < /dev/null
}

# pr_json <state> <draft> <mergeable> <mergeStateStatus> [head] [merge sha]
pr_json() {
  jq -cn --arg s "$1" --argjson d "$2" --arg m "$3" --arg ms "$4" --arg h "${5:-$HEAD_SHA}" --arg mc "${6:-}" \
    '{state: $s, isDraft: $d, isCrossRepository: false, headRefName: "app-7", headRefOid: $h, baseRefName: "main", mergeable: $m, mergeStateStatus: $ms,
      mergeCommit: (if $mc == "" then null else {oid: $mc} end)}'
}
# pr <args of pr_json>: every read of PR #9 returns this.
pr() { pr_json "$@" | fixture gh pr view 9 -R "$REPO" --json "$PR_FIELDS"; }
# pr_seq <n> <args of pr_json>: the nth read of PR #9 returns this; the last one repeats.
pr_seq() { n=$1; shift; pr_json "$@" | fixture_seq "$n" gh pr view 9 -R "$REPO" --json "$PR_FIELDS"; }
# review_comment <association> <head> [body]: a PR comment; the default body is the review station's.
review_comment() {
  body=$(printf 'factory review: round 1, tier low, head %s\nCovered: everything\nFindings: none' "$2")
  [ $# -lt 3 ] || body=$3
  jq -cn --arg a "$1" --arg b "$body" '{author_association: $a, body: $b}'
}
# reviewed <comment json...>: PR #9's comments.
reviewed() {
  printf '[%s]\n' "$(printf '%s\n' "$@" | paste -sd , -)" | fixture gh api "repos/$REPO/issues/9/comments" --paginate
}
checks() { printf '%s\n' "$1" | fixture gh pr checks 9 -R "$REPO" --required --json name,bucket; }
timeline() { printf '%s\n' "$1" | fixture gh api "repos/$REPO/issues/7/timeline" --paginate; }
ci_runs() { printf '%s\n' "$1" | fixture gh run list -R "$REPO" --workflow ci.yml --commit "$HEAD_SHA" --limit 20 --json databaseId,attempt,status,conclusion; }
sf_ship() { sh "$FACTORY_ROOT/bin/sf-ship" --repo "$REPO" 7 9; }

# ship_status: run sf-ship, keep stdout in $TEST_TMP/out and stderr in $TEST_TMP/err, set $status.
ship_status() {
  status=0
  sf_ship > "$TEST_TMP/out" 2> "$TEST_TMP/err" || status=$?
}
last_line() { tail -n 1 "$TEST_TMP/out"; }

test_auto_mode_readies_waits_and_merges_at_the_checked_head() {
  world auto
  pr_seq 1 OPEN true MERGEABLE CLEAN
  pr_seq 2 OPEN false MERGEABLE CLEAN
  pr_seq 3 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_eq "MERGED abc123" "$(last_line)" "result"
  assert_called "gantry-gate-evidence"
  assert_called "gantry-verdict-check --pr 9 --repo $REPO --no-label"
  assert_called "gh pr ready 9 -R $REPO"
  assert_called "gh pr merge 9 -R $REPO --squash --match-head-commit $HEAD_SHA"
  assert_eq 0 "$(count_calls "--admin")" "--admin calls"
  assert_eq 0 "$(count_calls "--auto")" "--auto calls"
  assert_eq 0 "$(count_calls "gh api repos/$REPO/pulls")" "REST merge calls"
}

test_already_merged_pr_exits_0_without_gates_or_merge() {
  world auto
  pr MERGED false UNKNOWN UNKNOWN "$HEAD_SHA" abc123
  ship_status
  assert_eq 0 "$status" "exit status"
  assert_eq "MERGED abc123" "$(last_line)" "result"
  assert_eq 0 "$(count_calls "gantry-")" "gate calls"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_supervised_mode_readies_the_pr_and_never_merges() {
  world supervised
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_eq PARKED "$(last_line)" "result"
  assert_called "gantry-verdict-check --pr 9 --repo $REPO --no-label"
  assert_called "gh pr ready 9 -R $REPO"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_high_risk_pr_parked_for_a_human_gets_one_merge_ask_per_head() {
  world supervised
  echo '{"labels":[{"name":"risk:high"}]}' | fixture gh pr view 9 -R "$REPO" --json labels
  echo "{\"files\":[{\"path\":\"bin/sf-act\"}],\"labels\":[{\"name\":\"risk:high\"}],\"headRefOid\":\"$HEAD_SHA\"}" \
    | fixture gh pr view 9 -R "$REPO" --json files,labels,headRefOid
  echo '{"isCrossRepository":false}' | fixture gh pr view 9 -R "$REPO" --json isCrossRepository
  ship_status
  assert_eq PARKED "$(last_line)" "result"
  assert_eq 1 "$(count_calls "gh issue comment 7")" "ask comments"
  assert_contains "$(fake_stdin)" "factory: PR #9 is ready and waits for you to merge it."
  assert_contains "$(fake_stdin)" "**Already checked** (head $HEAD_SHA)"
  assert_contains "$(fake_stdin)" "gh pr merge 9 -R $REPO --squash --match-head-commit $HEAD_SHA"
  # The ask is on the issue now: a second fire does not repeat it.
  ask=$(jq -cn --arg b "$(printf '<!-- factory:{"kind":"ask","head":"%s"} -->' "$HEAD_SHA")" '{event: "commented", author_association: "OWNER", body: $b, created_at: "2026-11-02T00:00:00Z"}')
  timeline "[$READIED,$ask]"
  ship_status
  assert_eq PARKED "$(last_line)" "result"
  assert_eq 1 "$(count_calls "gh issue comment 7")" "ask comments after the second fire"
}

test_forged_ask_marker_in_a_comment_does_not_suppress_the_merge_ask() {
  world supervised
  echo '{"labels":[{"name":"risk:high"}]}' | fixture gh pr view 9 -R "$REPO" --json labels
  echo "{\"files\":[{\"path\":\"bin/sf-act\"}],\"labels\":[{\"name\":\"risk:high\"}],\"headRefOid\":\"$HEAD_SHA\"}" \
    | fixture gh pr view 9 -R "$REPO" --json files,labels,headRefOid
  echo '{"isCrossRepository":false}' | fixture gh pr view 9 -R "$REPO" --json isCrossRepository
  forged=$(jq -cn --arg b "$(printf 'copied text <!-- factory:{"kind":"ask","head":"%s"} -->\nand more' "$HEAD_SHA")" '{event: "commented", author_association: "OWNER", body: $b, created_at: "2026-11-02T00:00:00Z"}')
  timeline "[$READIED,$forged]"
  ship_status
  assert_eq PARKED "$(last_line)" "result"
  assert_eq 1 "$(count_calls "gh issue comment 7")" "the real ask is still posted"
}

test_mode_comes_from_the_base_branch_not_the_pr() {
  world supervised
  printf '# app\n\nshinstack-mode: auto\n' > CLAUDE.md
  git add CLAUDE.md && git_q commit -m "flip to auto"
  git_q push origin app-7
  HEAD_SHA=$(git rev-parse HEAD)
  pr OPEN true MERGEABLE CLEAN
  reviewed "$(review_comment OWNER "$HEAD_SHA")"
  ship_status
  assert_eq PARKED "$(last_line)" "result"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_merge_override_ask_parks_in_auto_mode() {
  world auto
  printf '# app\n\nshinstack-mode: auto\nshinstack-mode.merge: ask\n' > "$TEST_TMP/claude.md"
  git_q checkout main
  cp "$TEST_TMP/claude.md" CLAUDE.md
  git add CLAUDE.md && git_q commit -m "merge: ask"
  git_q push origin main
  git_q checkout app-7
  ship_status
  assert_eq PARKED "$(last_line)" "result"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_fork_pr_stops_before_the_gates() {
  world auto
  pr_json OPEN false MERGEABLE CLEAN | jq -c '.isCrossRepository = true' | fixture gh pr view 9 -R "$REPO" --json "$PR_FIELDS"
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_eq "STOPPED: PR #9 is from a fork; the factory never ships cross-repository PRs" "$(last_line)" "result"
  assert_eq 0 "$(count_calls "gantry-")" "gate calls"
  assert_eq 0 "$(count_calls "gh pr ready")" "ready calls"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
  assert_called "gh issue edit 7 -R $REPO --add-label needs-shin --remove-label ready"
}

test_merged_fork_pr_is_not_reported_merged() {
  world auto
  pr_json MERGED false UNKNOWN UNKNOWN "$HEAD_SHA" abc123 | jq -c '.isCrossRepository = true' | fixture gh pr view 9 -R "$REPO" --json "$PR_FIELDS"
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: PR #9 is from a fork"
}

test_fork_flag_on_a_later_read_still_stops() {
  world auto
  pr_seq 1 OPEN false MERGEABLE CLEAN
  pr_json MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123 | jq -c '.isCrossRepository = true' | fixture_seq 2 gh pr view 9 -R "$REPO" --json "$PR_FIELDS"
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: PR #9 is from a fork"
}

test_pr_with_an_unreadable_cross_repository_flag_is_retried() {
  world auto
  pr_json OPEN false MERGEABLE CLEAN | jq -c 'del(.isCrossRepository)' | fixture gh pr view 9 -R "$REPO" --json "$PR_FIELDS"
  ship_status
  assert_eq 2 "$status" "exit status"
  assert_contains "$(last_line)" "RETRY: PR #9 not read: isCrossRepository"
  assert_eq 0 "$(count_calls "gantry-")" "gate calls"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_head_moved_is_refused_and_stopped() {
  world auto
  pr OPEN true MERGEABLE CLEAN 0123456789abcdef0123456789abcdef01234567
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: refused: PR #9 head moved"
  assert_eq 0 "$(count_calls "gantry-")" "gate calls"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
  assert_contains "$(fake_stdin)" "factory: stopped. refused: PR #9 head moved"
  assert_called "gh issue edit 7 -R $REPO --add-label needs-shin --remove-label ready"
}

test_head_moving_during_the_wait_is_refused() {
  world auto
  pr_seq 1 OPEN false MERGEABLE CLEAN
  pr_seq 2 OPEN false MERGEABLE CLEAN 0123456789abcdef0123456789abcdef01234567
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: refused: PR #9 head moved from $HEAD_SHA"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_pending_checks_wait_then_merge() {
  world auto
  pr_seq 1 OPEN false UNKNOWN UNKNOWN
  pr_seq 2 OPEN false UNKNOWN UNKNOWN
  pr_seq 3 OPEN false MERGEABLE BLOCKED
  pr_seq 4 OPEN false MERGEABLE CLEAN
  pr_seq 5 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  printf '[{"name":"gantry / ci-ok","bucket":"pending"}]\n' | fixture_seq 1 gh pr checks 9 -R "$REPO" --required --json name,bucket
  printf '[{"name":"gantry / ci-ok","bucket":"pass"}]\n' | fixture_seq 3 gh pr checks 9 -R "$REPO" --required --json name,bucket
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_eq "MERGED abc123" "$(last_line)" "result"
  assert_eq 3 "$(count_calls "gh pr checks 9")" "check reads"
  assert_contains "$(cat "$TEST_TMP/err")" "waiting on gantry / ci-ok"
}

test_checks_not_reported_yet_count_as_pending() {
  world auto
  pr_seq 1 OPEN false MERGEABLE BLOCKED
  pr_seq 3 OPEN false MERGEABLE CLEAN
  pr_seq 4 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  fixture_seq 1 gh pr checks 9 -R "$REPO" --required --json name,bucket < /dev/null
  fixture_exit 1 "no required checks reported on the 'app-7' branch"
  printf '[{"name":"gantry / ci-ok","bucket":"pass"}]\n' | fixture_seq 2 gh pr checks 9 -R "$REPO" --required --json name,bucket
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_contains "$(cat "$TEST_TMP/err")" "waiting on required checks not reported yet"
  assert_eq 1 "$(count_calls "gh pr merge 9")" "merge attempts"
}

test_blocked_with_no_required_checks_lets_gh_decide_after_the_wait() {
  world auto
  pr OPEN false MERGEABLE BLOCKED
  fixture gh pr checks 9 -R "$REPO" --required --json name,bucket < /dev/null
  fixture_exit 1 "no required checks reported on the 'app-7' branch"
  fixture gh pr merge 9 -R "$REPO" --squash --match-head-commit "$HEAD_SHA" < /dev/null
  fixture_exit 1 "X Pull request acme/app#9 is not mergeable: review required."
  ci_runs '[{"databaseId":5000,"attempt":1,"status":"completed","conclusion":"skipped"}]'
  SF_SHIP_WAIT=0 ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: merge refused: X Pull request acme/app#9 is not mergeable: review required."
}

test_checks_still_pending_after_the_wait_retry_without_stopping() {
  world auto
  pr OPEN false MERGEABLE BLOCKED
  checks '[{"name":"gantry / ci-ok","bucket":"pending"}]'
  SF_SHIP_WAIT=0 ship_status
  assert_eq 2 "$status" "exit status"
  assert_contains "$(last_line)" "RETRY: PR #9 still pending after 0s: gantry / ci-ok"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
  assert_eq 0 "$(count_calls "gh issue comment")" "stop comments"
}

test_failed_required_check_stops() {
  world auto
  pr OPEN false MERGEABLE BLOCKED
  checks '[{"name":"gantry / ci-ok","bucket":"fail"},{"name":"check (ubuntu-latest)","bucket":"pass"}]'
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_eq "STOPPED: required checks failed on PR #9: gantry / ci-ok" "$(last_line)" "result"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_evidence_gate_failure_stops_with_its_output() {
  world auto
  fixture gantry-gate-evidence <<'OUT'
FAIL: pre-push hook refused the push
OUT
  fixture_exit 1
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: evidence gate failed: FAIL: pre-push hook refused the push"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_gate_exit_2_is_retried_not_stopped() {
  world auto
  fixture gantry-verdict-check --pr 9 --repo "$REPO" --no-label < /dev/null
  fixture_exit 2 "gh: HTTP 502"
  ship_status
  assert_eq 2 "$status" "exit status"
  assert_contains "$(last_line)" "RETRY: gantry-verdict-check exited 2"
  assert_eq 0 "$(count_calls "gh issue comment")" "stop comments"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_stale_verdict_stops() {
  world auto
  fixture gantry-verdict-check --pr 9 --repo "$REPO" --no-label <<'OUT'
FAIL: verdict head_sha 1111111 is not PR head
OUT
  fixture_exit 1
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: verdict check failed: FAIL: verdict head_sha 1111111"
}

test_bug_issue_runs_the_test_first_gate() {
  world auto
  echo "bug,ready" | fixture gh issue view 7 -R "$REPO" --json labels -q '[.labels[].name] | join(",")'
  echo "PASS" | fixture gantry-gate-evidence --bug
  pr_seq 1 OPEN false MERGEABLE CLEAN
  pr_seq 3 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_called "gantry-gate-evidence --bug"
}

# origin/main gains a commit that touches another file, so a rebase is clean.
advance_main() {
  git_q checkout main
  commit "${1:-other.txt}" "${2:-from main}"
  git_q push origin main
  git_q checkout app-7
  git_q reset --hard "$HEAD_SHA"
  # Leave the local main behind, as in a worker's checkout.
  git_q branch -f main HEAD~1
}

test_first_conflict_rebases_pushes_with_lease_and_asks_for_rereview() {
  world auto
  advance_main
  pr OPEN false CONFLICTING DIRTY
  echo "PASS: pushed" | fixture gantry-gate-evidence --force-with-lease
  ship_status
  assert_eq 3 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  new_head=$(git rev-parse HEAD)
  assert_eq "REREVIEW: PR #9 rebased onto main, now at $new_head" "$(last_line)" "result"
  git merge-base --is-ancestor origin/main HEAD || fail "HEAD is not on top of origin/main"
  assert_eq 0 "$(git rev-list --merges --count origin/main..HEAD)" "merge commits on the branch"
  assert_called "gantry-gate-evidence --force-with-lease"
  assert_contains "$(fake_stdin)" "<!-- factory:{\"kind\":\"rebase\",\"pr\":9,\"from\":\"$HEAD_SHA\",\"to\":\"$new_head\"} -->"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
  assert_eq 0 "$(count_calls "gh issue edit")" "label edits"
}

# origin/main and app-7 both edit shared.txt (different ends, so the rebase has no conflict) while
# GitHub still reads the PR as clean: the pre-merge review and CI cover a head main has moved past.
overlap_world() {
  world auto
  printf 'top\nmid\nbottom\n' > shared.txt
  git add shared.txt && git_q commit -m "shared base"
  git_q push origin app-7
  git_q checkout main
  git_q reset --hard origin/main
  printf 'top\nmid\nbottom\n' > shared.txt
  git add shared.txt && git_q commit -m "shared base on main"
  git_q push origin main
  git_q checkout app-7
  git_q rebase main
  git_q push --force origin app-7
  printf 'top\nmid\nbottom\nfrom app-7\n' > shared.txt
  git add shared.txt && git_q commit -m "app-7 edits shared.txt"
  git_q push --force origin app-7
  HEAD_SHA=$(git rev-parse HEAD)
  git_q checkout main
  printf 'from main\ntop\nmid\nbottom\n' > shared.txt
  git add shared.txt && git_q commit -m "main edits shared.txt"
  git_q push origin main
  git_q checkout app-7
  git_q branch -f main "$HEAD_SHA"
}

test_clean_pr_whose_base_moved_on_a_shared_file_rebases_and_asks_for_rereview() {
  overlap_world
  reviewed "$(review_comment OWNER "$HEAD_SHA")"
  pr OPEN false MERGEABLE CLEAN
  echo "PASS: pushed" | fixture gantry-gate-evidence --force-with-lease
  ship_status
  assert_eq 3 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  new_head=$(git rev-parse HEAD)
  assert_eq "REREVIEW: PR #9 rebased onto main, now at $new_head; main also changed shared.txt" "$(last_line)" "result"
  git merge-base --is-ancestor origin/main HEAD || fail "HEAD is not on top of origin/main"
  assert_contains "$(fake_stdin)" "main also changed shared.txt"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_clean_pr_whose_base_moved_on_other_files_still_merges() {
  world auto
  advance_main
  pr_seq 1 OPEN false MERGEABLE CLEAN
  pr_seq 3 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_eq "MERGED abc123" "$(last_line)" "result"
  assert_eq 0 "$(count_calls "--force-with-lease")" "pushes"
}

test_behind_base_also_rebases() {
  world auto
  advance_main
  pr OPEN false MERGEABLE BEHIND
  echo "PASS" | fixture gantry-gate-evidence --force-with-lease
  ship_status
  assert_eq 3 "$status" "exit status ($(cat "$TEST_TMP/err"))"
}

test_second_conflict_stops() {
  world auto
  advance_main
  rebased='{"event":"commented","author_association":"OWNER","body":"<!-- factory:{\"kind\":\"rebase\",\"pr\":9} -->","created_at":"2026-11-02T00:00:00Z"}'
  timeline "[$READIED,$rebased]"
  pr OPEN false CONFLICTING DIRTY
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_eq "STOPPED: PR #9 conflicts with main again after one rebase" "$(last_line)" "result"
  assert_eq "$HEAD_SHA" "$(git rev-parse HEAD)" "HEAD"
  assert_eq 0 "$(count_calls "gantry-gate-evidence --force-with-lease")" "pushes"
  assert_called "gh issue edit 7 -R $REPO --add-label needs-shin --remove-label ready"
}

test_rebase_from_a_previous_ready_round_does_not_count() {
  world auto
  advance_main
  old='{"event":"commented","author_association":"OWNER","body":"<!-- factory:{\"kind\":\"rebase\",\"pr\":9} -->","created_at":"2026-10-01T00:00:00Z"}'
  timeline "[$old,$READIED]"
  pr OPEN false CONFLICTING DIRTY
  echo "PASS" | fixture gantry-gate-evidence --force-with-lease
  ship_status
  assert_eq 3 "$status" "exit status ($(cat "$TEST_TMP/err"))"
}

test_rebase_with_conflicting_files_stops_and_restores_the_branch() {
  world auto
  advance_main feature.txt "main's version"
  pr OPEN false CONFLICTING DIRTY
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_eq "STOPPED: rebase of PR #9 onto main conflicts in: feature.txt " "$(last_line)" "result"
  assert_eq "$HEAD_SHA" "$(git rev-parse HEAD)" "HEAD"
  assert_eq "" "$(git status --porcelain)" "worktree status"
}

test_push_failure_after_rebase_restores_the_branch_and_retries() {
  world auto
  advance_main
  pr OPEN false CONFLICTING DIRTY
  fixture gantry-gate-evidence --force-with-lease < /dev/null
  fixture_exit 2 "fatal: unable to access remote"
  ship_status
  assert_eq 2 "$status" "exit status"
  assert_eq "$HEAD_SHA" "$(git rev-parse HEAD)" "HEAD"
  assert_eq 0 "$(count_calls "gh issue comment")" "comments (no rebase marker, no stop)"
}

test_refused_merge_reruns_green_ci_once_then_merges() {
  world auto
  pr_seq 1 OPEN false MERGEABLE CLEAN
  pr_seq 4 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  fixture gh pr merge 9 -R "$REPO" --squash --match-head-commit "$HEAD_SHA" < /dev/null
  fixture_exit 1 "X Pull request acme/app#9 is not mergeable: the base branch policy prohibits the merge."
  ci_runs '[{"databaseId":5000,"attempt":1,"status":"completed","conclusion":"skipped"},{"databaseId":4242,"attempt":1,"status":"completed","conclusion":"success"}]'
  fixture gh run rerun 4242 -R "$REPO" < /dev/null
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_eq "MERGED abc123" "$(last_line)" "result"
  assert_called "gh run rerun 4242 -R $REPO"
}

test_merge_refused_twice_stops_with_the_refusal() {
  world auto
  pr OPEN false MERGEABLE CLEAN
  fixture gh pr merge 9 -R "$REPO" --squash --match-head-commit "$HEAD_SHA" < /dev/null
  fixture_exit 1 "X Pull request acme/app#9 is not mergeable: the base branch policy prohibits the merge."
  ci_runs '[{"databaseId":5000,"attempt":1,"status":"completed","conclusion":"skipped"},{"databaseId":4242,"attempt":1,"status":"completed","conclusion":"success"}]'
  fixture gh run rerun 4242 -R "$REPO" < /dev/null
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: merge refused: X Pull request acme/app#9 is not mergeable: the base branch policy prohibits the merge."
  assert_eq 2 "$(count_calls "gh pr merge 9")" "merge attempts"
  assert_eq 1 "$(count_calls "gh run rerun")" "reruns"
}

test_rerun_is_not_repeated_on_a_later_fire() {
  world auto
  pr OPEN false MERGEABLE CLEAN
  fixture gh pr merge 9 -R "$REPO" --squash --match-head-commit "$HEAD_SHA" < /dev/null
  fixture_exit 1 "X Pull request acme/app#9 is not mergeable: the base branch policy prohibits the merge."
  # An earlier fire already reran 4242; it is still running.
  ci_runs '[{"databaseId":4242,"attempt":2,"status":"in_progress","conclusion":""}]'
  ship_status
  assert_eq 2 "$status" "exit status while the rerun runs"
  assert_contains "$(last_line)" "RETRY: merge refused while ci run 4242 reruns"
  # Next fire: the rerun finished and the merge is still refused.
  ci_runs '[{"databaseId":4242,"attempt":2,"status":"completed","conclusion":"success"}]'
  ship_status
  assert_eq 1 "$status" "exit status after the rerun"
  assert_contains "$(last_line)" "STOPPED: merge refused: X Pull request acme/app#9"
  assert_eq 0 "$(count_calls "gh run rerun")" "reruns"
}

test_dirty_worktree_stops_before_the_gates() {
  world auto
  echo local > feature.txt
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: sf-ship ran in a worktree with uncommitted or untracked files on app-7"
  assert_eq 0 "$(count_calls "gantry-")" "gate calls"
}

test_gate_exit_2_after_its_push_landed_still_asks_for_rereview() {
  world auto
  advance_main
  pr OPEN false CONFLICTING DIRTY
  fixture gantry-gate-evidence --force-with-lease < /dev/null
  fixture_exit 2 "gh: HTTP 502 after push"
  # Reading the PR back after the gate shows the rebased head: the push landed. A fixed
  # committer date makes sf-ship's rebase produce the same sha as this one.
  GIT_COMMITTER_DATE="2026-11-15T00:00:00Z"
  export GIT_COMMITTER_DATE
  git_q fetch origin main
  rebased=$(git rebase -q origin/main > /dev/null 2>&1 && git rev-parse HEAD)
  git_q reset --hard "$HEAD_SHA"
  pr_seq 1 OPEN false CONFLICTING DIRTY
  pr_seq 3 OPEN false MERGEABLE CLEAN "$rebased"
  ship_status
  assert_eq 3 "$status" "exit status ($(cat "$TEST_TMP/out"))"
  assert_contains "$(fake_stdin)" '"kind":"rebase"'
}

test_merge_refused_with_no_green_ci_run_stops_at_once() {
  world auto
  pr OPEN false MERGEABLE CLEAN
  fixture gh pr merge 9 -R "$REPO" --squash --match-head-commit "$HEAD_SHA" < /dev/null
  fixture_exit 1 "X Head branch was modified. Review and try the merge again."
  ci_runs '[{"databaseId":5000,"attempt":1,"status":"completed","conclusion":"skipped"}]'
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: merge refused: X Head branch was modified."
  assert_eq 1 "$(count_calls "gh pr merge 9")" "merge attempts"
}

test_worktree_on_another_branch_stops() {
  world auto
  git_q checkout main
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: sf-ship ran in a worktree on branch main, not PR #9's branch app-7"
  assert_eq 0 "$(count_calls "gantry-")" "gate calls"
}

test_no_review_comment_for_the_head_stops_before_merging() {
  world auto
  reviewed "$(review_comment OWNER 0000000000000000000000000000000000000000)" "$(review_comment NONE "$HEAD_SHA")"
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: no review for PR #9 head $HEAD_SHA" "last line"
  assert_not_called "gh pr merge 9 -R $REPO --squash --match-head-commit $HEAD_SHA"
  assert_not_called "gh pr ready 9 -R $REPO"
}

test_codex_not_run_comment_counts_as_the_review() {
  world auto
  pr_seq 1 OPEN true MERGEABLE CLEAN
  pr_seq 2 OPEN false MERGEABLE CLEAN
  pr_seq 3 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  reviewed "$(review_comment OWNER "$HEAD_SHA" "factory: Codex review not run: codex not installed (head $HEAD_SHA)")"
  ship_status
  assert_eq 0 "$status" "exit status"
  assert_eq "MERGED abc123" "$(last_line)" "last line"
}

test_comment_without_a_findings_line_is_not_a_review() {
  world auto
  reviewed "$(review_comment OWNER "$HEAD_SHA" "Covered: everything at $HEAD_SHA")"
  ship_status
  assert_eq 1 "$status" "exit status"
  assert_contains "$(last_line)" "STOPPED: no review for PR #9" "last line"
}

# Seen in the e2e (#7): a repo with no CI has no checks at all; that must not retry forever.
test_a_repo_with_no_checks_at_all_merges() {
  world auto
  pr_seq 1 OPEN false MERGEABLE CLEAN
  pr_seq 3 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  fixture gh pr checks 9 -R "$REPO" --required --json name,bucket < /dev/null
  fixture_exit 1 "no checks reported on the 'app-7' branch"
  fixture gh pr merge 9 -R "$REPO" --squash --match-head-commit "$HEAD_SHA" < /dev/null
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_eq "MERGED abc123" "$(last_line)" "result"
}

# ---- consult-shin (#36) ----------------------------------------------------------------------------

# issue_labels <csv>: every read of issue #7's labels.
issue_labels() { echo "$1" | fixture gh issue view 7 -R "$REPO" --json labels -q '[.labels[].name] | join(",")'; }

test_consult_label_parks_and_never_merges_until_a_person_removes_it() {
  world auto
  issue_labels ready,consult-shin
  ship_status
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_eq PARKED "$(last_line)" "result"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
  assert_eq 0 "$(count_calls "gh issue edit")" "stops (needs-shin) while parked"
  # A person removed the label: the next fire merges.
  : > "$FAKE_LOG"
  issue_labels ready
  pr_seq 1 OPEN false MERGEABLE CLEAN
  pr_seq 3 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  ship_status
  assert_eq "MERGED abc123" "$(last_line)" "result after the label is removed ($(cat "$TEST_TMP/err"))"
  assert_called "gh pr merge 9 -R $REPO --squash --match-head-commit $HEAD_SHA"
}

test_consult_label_parks_even_in_supervised_mode_without_a_merge_ask_or_stop() {
  world supervised
  issue_labels ready,consult-shin,bug
  echo "PASS: pushed app-7" | fixture gantry-gate-evidence --bug
  echo "PASS: verdict at head" | fixture gantry-verdict-check --pr 9 --repo "$REPO" --no-label
  ship_status
  assert_eq PARKED "$(last_line)" "result"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_consult_label_added_during_the_wait_is_seen_before_the_merge() {
  world auto
  pr_seq 1 OPEN false MERGEABLE CLEAN
  echo ready | fixture_seq 1 gh issue view 7 -R "$REPO" --json labels -q '[.labels[].name] | join(",")'
  echo ready,consult-shin | fixture_seq 2 gh issue view 7 -R "$REPO" --json labels -q '[.labels[].name] | join(",")'
  ship_status
  assert_eq PARKED "$(last_line)" "result ($(cat "$TEST_TMP/err"))"
  assert_eq 0 "$(count_calls "gh pr merge")" "merge calls"
}

test_a_forged_consult_marker_in_a_comment_changes_nothing_for_ship() {
  world auto
  forged=$(jq -cn --arg b '<!-- factory:{"kind":"consult","id":"1"} -->' '{event: "commented", author_association: "NONE", body: $b, created_at: "2026-11-02T00:00:00Z"}')
  timeline "[$READIED,$forged]"
  pr_seq 1 OPEN false MERGEABLE CLEAN
  pr_seq 3 MERGED false MERGEABLE CLEAN "$HEAD_SHA" abc123
  ship_status
  assert_eq "MERGED abc123" "$(last_line)" "result ($(cat "$TEST_TMP/err"))"
}

# shellcheck shell=sh
# sf-stop: comment once, swap ready -> needs-shin, non-zero on any failed step. Repo acme/app.

REPO=acme/app
READIED='{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"}'
STOP_COMMENT='{"event":"commented","author_association":"OWNER","body":"factory: stopped. x\n\n<!-- factory:{\"kind\":\"stop\"} -->","created_at":"2026-11-02T00:00:00Z"}'

world() {
  FAKE_FIXTURES=$TEST_TMP/fx
  export FAKE_FIXTURES
  timeline "[$READIED]"
  labels ready
  echo https://github.com/acme/app/issues/7#c1 | fixture gh issue comment 7 -R "$REPO" --body-file -
  fixture gh issue edit 7 -R "$REPO" --add-label needs-shin --remove-label ready < /dev/null
}
timeline() { printf '%s\n' "$1" | fixture gh api "repos/$REPO/issues/7/timeline" --paginate; }
labels() { printf '%s\n' "$1" | fixture gh issue view 7 -R "$REPO" --json labels -q '[.labels[].name] | join(",")'; }
sf_stop() { sh "$FACTORY_ROOT/bin/sf-stop" --repo "$REPO" "$@"; }

test_stop_comments_and_swaps_labels() {
  world
  sf_stop 7 "verdict check failed" > "$TEST_TMP/out"
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments"
  assert_contains "$(fake_stdin)" "factory: stopped. verdict check failed"
  assert_contains "$(fake_stdin)" '<!-- factory:{"kind":"stop"} -->'
  assert_called "gh issue edit 7 -R $REPO --add-label needs-shin --remove-label ready"
}

# pr_world <labels json> <comments json>: PR #9's files, labels, head and comments.
HEAD=0123456789abcdef0123456789abcdef01234567
pr_world() {
  world
  printf '{"files":[{"path":"bin/sf-act"},{"path":"lib/x.sh"}],"labels":%s,"headRefOid":"%s"}\n' "$1" "$HEAD" \
    | fixture gh pr view 9 -R "$REPO" --json files,labels,headRefOid
  printf '%s\n' "$2" | fixture gh api "repos/$REPO/issues/9/comments" --paginate
}
station() { jq -cn --arg b "$1" '{author_association: "OWNER", body: $b}'; }

test_stop_comment_carries_the_four_parts_and_one_action() {
  pr_world '[{"name":"risk:high"}]' "[$(station "factory review: round 1, head $HEAD
Covered: all
Findings: none")]"
  sf_stop --pr 9 7 "review r2: findings in round 2 (https://x/c2)" > /dev/null
  body=$(fake_stdin)
  assert_contains "$body" "factory: stopped. review r2: findings in round 2 (https://x/c2)"
  assert_contains "$body" "**What this changes:** PR #9 touches: bin/sf-act, lib/x.sh."
  assert_contains "$body" "**Why it is risky:** labelled risk:high"
  assert_contains "$body" "**Already checked** (head $HEAD): factory review: round 1, head $HEAD / Findings: none"
  assert_contains "$body" "gh pr diff 9 -R $REPO"
  assert_contains "$body" "**Recommended:** Read the reason"
  assert_contains "$body" '<!-- factory:{"kind":"stop"} -->'
}

test_stop_says_when_a_fix_landed_after_the_last_review() {
  pr_world '[{"name":"risk:high"}]' "[$(station "factory review: round 1, head aaaaaaa
Covered: all
Findings: none")]"
  sf_stop --pr 9 7 "x" > /dev/null
  body=$(fake_stdin)
  assert_contains "$body" "A fix landed after the last review, so no station has seen this head."
  assert_contains "$body" "no station comment names this head"
  assert_contains "$body" "**Recommended:** Label the issue ready again so review and verify rerun"
}

test_stop_without_a_pr_says_what_is_unknown() {
  world
  sf_stop 7 "intake brief not rendered" > /dev/null
  body=$(fake_stdin)
  assert_contains "$body" "**What this changes:** unknown: there is no PR yet."
  assert_contains "$body" "**Why it is risky:** unknown: no risk label read."
  assert_contains "$body" "**Already checked:** unknown: no PR head SHA read."
  assert_contains "$body" "**Recommended:**"
}

test_stop_still_posts_when_the_pr_data_is_unreadable() {
  world
  sf_stop --pr 9 7 "reason" > /dev/null
  assert_contains "$(fake_stdin)" "**What this changes:** PR #9 files not read from GitHub."
  assert_called "gh issue edit 7 -R $REPO --add-label needs-shin --remove-label ready"
}

test_stop_twice_leaves_one_comment() {
  world
  sf_stop 7 "reason" > /dev/null
  # GitHub now has the comment and the labels.
  timeline "[$READIED,$STOP_COMMENT]"
  labels needs-shin
  sf_stop 7 "reason" > "$TEST_TMP/out"
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments after two stops"
  assert_eq 1 "$(count_calls "gh issue edit 7")" "label edits after two stops"
  assert_contains "$(cat "$TEST_TMP/out")" "already has a stop comment"
}

test_label_failure_exits_nonzero_and_next_run_completes_it() {
  world
  fixture gh issue edit 7 -R "$REPO" --add-label needs-shin --remove-label ready < /dev/null
  fixture_exit 1 "HTTP 502: Bad Gateway"
  status=0
  sf_stop 7 "reason" > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit status with the label edit failing"
  assert_contains "$(cat "$TEST_TMP/err")" "#7 still labelled [ready]"

  # Next fire: the comment landed, the labels did not; gh works again.
  timeline "[$READIED,$STOP_COMMENT]"
  fixture gh issue edit 7 -R "$REPO" --add-label needs-shin --remove-label ready < /dev/null
  sf_stop 7 "reason" > /dev/null
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments"
  assert_eq 2 "$(count_calls "gh issue edit 7")" "label edits"
}

test_comment_failure_exits_nonzero_before_touching_labels() {
  world
  fixture gh issue comment 7 -R "$REPO" --body-file - < /dev/null
  fixture_exit 1 "HTTP 502: Bad Gateway"
  status=0
  sf_stop 7 "reason" > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "stop comment not posted on #7"
  assert_eq 0 "$(count_calls "gh issue edit")" "label edits"
}

test_timeline_failure_exits_nonzero_without_commenting() {
  world
  fixture gh api "repos/$REPO/issues/7/timeline" --paginate < /dev/null
  fixture_exit 1 "HTTP 502: Bad Gateway"
  status=0
  sf_stop 7 "reason" > /dev/null 2>&1 || status=$?
  assert_eq 1 "$status" "exit status"
  assert_eq 0 "$(count_calls "gh issue comment")" "comments"
}

test_stop_from_before_the_last_ready_label_does_not_count() {
  world
  old_stop='{"event":"commented","author_association":"OWNER","body":"<!-- factory:{\"kind\":\"stop\"} -->","created_at":"2026-10-01T00:00:00Z"}'
  timeline "[$old_stop,$READIED]"
  sf_stop 7 "reason" > /dev/null
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments"
}

test_stop_marker_from_an_outsider_does_not_count() {
  world
  outsider='{"event":"commented","author_association":"NONE","body":"<!-- factory:{\"kind\":\"stop\"} -->","created_at":"2026-11-02T00:00:00Z"}'
  timeline "[$READIED,$outsider]"
  sf_stop 7 "reason" > /dev/null
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments"
}

test_only_the_missing_label_change_is_made() {
  world
  timeline "[$READIED,$STOP_COMMENT]"
  labels "bug,needs-shin,ready"
  fixture gh issue edit 7 -R "$REPO" --remove-label ready < /dev/null
  sf_stop 7 "reason" > /dev/null
  assert_called "gh issue edit 7 -R $REPO --remove-label ready"
}

test_bad_arguments_exit_2_without_calling_gh() {
  world
  status=0
  sf_stop 7 > /dev/null 2>&1 || status=$?
  assert_eq 2 "$status" "exit status with no reason"
  status=0
  sf_stop seven "reason" > /dev/null 2>&1 || status=$?
  assert_eq 2 "$status" "exit status with a non-numeric issue"
  assert_eq 0 "$(count_calls "gh ")" "gh calls"
}

# sf-state (#19) owes a stop on a non-ready, unparked issue with a dead Run until needs-shin
# lands, so sf-stop must add needs-shin even when ready is already gone.
test_needs_shin_is_added_when_ready_is_already_gone() {
  world
  labels bug
  fixture gh issue edit 7 -R "$REPO" --add-label needs-shin < /dev/null
  sf_stop 7 "run r1 task build failed" > /dev/null
  assert_called "gh issue edit 7 -R $REPO --add-label needs-shin"
  assert_eq 1 "$(count_calls "gh issue edit 7")" "label edits"
}

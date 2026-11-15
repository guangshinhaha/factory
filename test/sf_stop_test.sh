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

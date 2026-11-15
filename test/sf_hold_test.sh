# shellcheck shell=sh
# sf-hold: a hold marker sf-state can read (provider + UTC Z reset), posted once. Repo acme/app.

REPO=acme/app
READIED='{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"}'
MARKER='<!-- factory:{"kind":"hold","provider":"claude","reset":"2026-11-15T10:00:00Z"} -->'

world() {
  FAKE_FIXTURES=$TEST_TMP/fx
  export FAKE_FIXTURES
  timeline "[$READIED]"
  echo https://github.com/acme/app/issues/7#c1 | fixture gh issue comment 7 -R "$REPO" --body-file -
}
timeline() { printf '%s\n' "$1" | fixture gh api "repos/$REPO/issues/7/timeline" --paginate; }
# marker_comment <json> <created_at>: a trusted comment carrying <!-- factory:<json> -->.
marker_comment() {
  jq -cn --arg m "$1" --arg t "$2" '{event: "commented", author_association: "OWNER", body: "<!-- factory:\($m) -->", created_at: $t}'
}
sf_hold() { sh "$FACTORY_ROOT/bin/sf-hold" --repo "$REPO" "$@"; }

test_hold_posts_the_marker_sf_state_reads() {
  world
  sf_hold 7 claude 2026-11-15T10:00:00Z > /dev/null
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments"
  assert_contains "$(fake_stdin)" "$MARKER"
  assert_eq 0 "$(count_calls "gh issue edit")" "label edits"
}

test_hold_twice_leaves_one_comment() {
  world
  sf_hold 7 claude 2026-11-15T10:00:00Z > /dev/null
  timeline "[$READIED,$(marker_comment '{"kind":"hold","provider":"claude","reset":"2026-11-15T10:00:00Z"}' 2026-11-02T00:00:00Z)]"
  sf_hold 7 claude 2026-11-15T10:00:00Z > "$TEST_TMP/out"
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments after two holds"
  assert_contains "$(cat "$TEST_TMP/out")" "already held for claude until 2026-11-15T10:00:00Z"
}

test_a_new_reset_posts_a_new_hold() {
  world
  timeline "[$READIED,$(marker_comment '{"kind":"hold","provider":"claude","reset":"2026-11-15T10:00:00Z"}' 2026-11-02T00:00:00Z)]"
  sf_hold 7 codex 2026-11-15T12:00:00Z > /dev/null
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments"
  assert_contains "$(fake_stdin)" '"provider":"codex","reset":"2026-11-15T12:00:00Z"'
}

test_a_hold_consumed_by_a_restart_is_posted_again() {
  world
  hold=$(marker_comment '{"kind":"hold","provider":"claude","reset":"2026-11-15T10:00:00Z"}' 2026-11-02T00:00:00Z)
  restart=$(marker_comment '{"kind":"restart"}' 2026-11-03T00:00:00Z)
  timeline "[$READIED,$hold,$restart]"
  sf_hold 7 claude 2026-11-15T10:00:00Z > /dev/null
  assert_eq 1 "$(count_calls "gh issue comment 7")" "comments"
}

test_a_reset_not_in_utc_z_form_is_refused() {
  world
  for reset in 2026-11-15T10:00:00+08:00 2026-11-15 "in 3 hours" 2026-13-45T99:00:00Z; do
    status=0
    sf_hold 7 claude "$reset" > /dev/null 2> "$TEST_TMP/err" || status=$?
    assert_eq 2 "$status" "exit status for reset [$reset]"
    assert_contains "$(cat "$TEST_TMP/err")" "reset [$reset] is not"
  done
  assert_eq 0 "$(count_calls "gh ")" "gh calls"
}

test_a_bad_provider_is_refused() {
  world
  status=0
  sf_hold 7 "Claude Code" 2026-11-15T10:00:00Z > /dev/null 2>&1 || status=$?
  assert_eq 2 "$status" "exit status"
}

test_comment_failure_exits_nonzero() {
  world
  fixture gh issue comment 7 -R "$REPO" --body-file - < /dev/null
  fixture_exit 1 "HTTP 502: Bad Gateway"
  status=0
  sf_hold 7 claude 2026-11-15T10:00:00Z > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "hold comment not posted on #7"
}

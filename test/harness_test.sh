# shellcheck shell=sh
# Tests for the harness itself: the fakes replay fixtures, and the guard
# fails any test that reaches a real gh or orca.

test_fake_gh_replays_fixture_and_logs_call() {
  use_fixtures harness
  out=$(gh issue list -R guangshinhaha/factory --label ready --json number,title)
  assert_eq '[{"number":2,"title":"Plugin scaffold"}]' "$out" "gh output"
  assert_called "gh issue list -R guangshinhaha/factory --label ready --json number,title"
}

test_fake_orca_replays_fixture_and_logs_call() {
  use_fixtures harness
  out=$(orca run list --json)
  assert_eq '[{"id":"run-1","status":"running"}]' "$out" "orca output"
  assert_called "orca run list --json"
  assert_not_called "gh run list --json"
}

test_fixture_replays_stderr_and_exit_status() {
  use_fixtures harness
  status=0
  gh api rate_limit 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "API rate limit exceeded" "stderr"
}

test_call_with_no_fixture_fails_and_names_the_missing_file() {
  use_fixtures harness
  status=0
  gh pr view 9 2> "$TEST_TMP/err" || status=$?
  assert_eq 97 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "missing $FAKE_FIXTURES/gh/pr_view_9.out" "stderr"
  assert_called "gh pr view 9"
}

# The guard case calls gh and ignores its failure. With every fake present it
# passes; with the gh fake deleted the guard must fail it anyway.
test_guard_fails_a_test_when_the_gh_fake_is_missing() {
  case_file=$FACTORY_ROOT/test/fixtures/selftest/guard_case.sh

  "$FACTORY_ROOT/test/run" "$case_file" > "$TEST_TMP/with-fake" 2>&1 \
    || fail "guard case failed with the fake present: $(cat "$TEST_TMP/with-fake")"

  mkdir "$TEST_TMP/fakes"
  cp "$FACTORY_ROOT/test/fakes/fake-cli" "$FACTORY_ROOT/test/fakes/orca" "$TEST_TMP/fakes/"
  status=0
  FACTORY_FAKES=$TEST_TMP/fakes "$FACTORY_ROOT/test/run" "$case_file" > "$TEST_TMP/no-fake" 2>&1 || status=$?
  assert_eq 1 "$status" "runner status with the gh fake deleted"
  assert_contains "$(cat "$TEST_TMP/no-fake")" "guard: real gh reached" "runner output"
  assert_contains "$(cat "$TEST_TMP/no-fake")" "0 passed, 1 failed" "runner summary"
}

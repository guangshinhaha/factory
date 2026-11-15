# shellcheck shell=sh
# Run by harness_test.sh, not directly: test/run only picks up test/*_test.sh.
# It swallows gh's failure on purpose, so only the guard can fail it.

test_calls_gh_and_ignores_failure() {
  use_fixtures harness
  gh issue list -R guangshinhaha/factory --label ready --json number,title > /dev/null || true
}

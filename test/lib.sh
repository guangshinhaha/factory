# shellcheck shell=sh
# Test helpers, sourced by test/run before each test file.
# test/run sets these before a test function starts:
#   FAKE_LOG       every fake gh/orca call, one line each
#   FAKE_FIXTURES  empty until use_fixtures picks a set
#   TEST_TMP       scratch dir for this test, removed afterwards
# PATH starts with the fakes dir, then a guard dir whose gh/orca fail the test.

# Point the fakes at test/fixtures/<name>.
use_fixtures() {
  FAKE_FIXTURES="$FACTORY_ROOT/test/fixtures/$1"
  if [ ! -d "$FAKE_FIXTURES" ]; then
    fail "fixture set not found: test/fixtures/$1"
  fi
  export FAKE_FIXTURES
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  # assert_eq <expected> <actual> [what]
  if [ "$1" != "$2" ]; then
    fail "${3:-value}: expected [$1], got [$2]"
  fi
}

assert_contains() {
  # assert_contains <haystack> <needle> [what]
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-output} does not contain [$2]: [$1]" ;;
  esac
}

# The exact call line was logged by a fake, e.g. assert_called "gh issue list".
assert_called() {
  if ! grep -Fxq -- "$1" "$FAKE_LOG" 2>/dev/null; then
    fail "call not logged: [$1]; calls were: [$(cat "$FAKE_LOG" 2>/dev/null)]"
  fi
}

assert_not_called() {
  if grep -Fxq -- "$1" "$FAKE_LOG" 2>/dev/null; then
    fail "call logged but should not be: [$1]"
  fi
}

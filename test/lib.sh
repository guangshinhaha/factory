# shellcheck shell=sh
# Test helpers, sourced by test/run before each test file.
# test/run sets these before a test function starts:
#   FAKE_LOG       every fake gh/orca call, one line each
#   FAKE_FIXTURES  empty until use_fixtures picks a set
#   TEST_TMP       scratch dir for this test, removed afterwards
# PATH starts with the fakes dir, then a guard dir whose gh/orca fail the test.

# mkkey: the fakes' fixture key function, loaded once here instead of one `sh fake-cli --key` per call.
# shellcheck source=/dev/null # not followed: fake-cli exits, which would mark the rest of this file unreachable
FAKE_CLI_LIB=1 . "$FACTORY_ROOT/test/fakes/fake-cli"
unset FAKE_CLI_LIB

# repoint_origin <repo> <url>: set origin's url in <repo>/.git/config in-process (git remote set-url, no git run).
repoint_origin() {
  ro_new=
  while IFS= read -r ro_l || [ -n "$ro_l" ]; do
    case $ro_l in
      "	url = "*) ro_l="	url = $2" ;;
    esac
    ro_new=$ro_new$ro_l'
'
  done < "$1/.git/config"
  printf '%s' "$ro_new" > "$1/.git/config"
}

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

# assert_status0 <status> <what> <errfile>: the status is 0; the failure message carries the file's text, read only on failure.
assert_status0() {
  [ "$1" = 0 ] || assert_eq 0 "$1" "$2 ($(cat "$3"))"
}

assert_contains() {
  # assert_contains <haystack> <needle> [what]
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-output} does not contain [$2]: [$1]" ;;
  esac
}

# log_has <line>: the fake log holds exactly that line. Read in-process: a grep per assert is a process per assert.
log_has() {
  [ -f "$FAKE_LOG" ] || return 1
  while IFS= read -r lh_l || [ -n "$lh_l" ]; do
    [ "$lh_l" != "$1" ] || return 0
  done < "$FAKE_LOG"
  return 1
}

# The exact call line was logged by a fake, e.g. assert_called "gh issue list".
assert_called() {
  if ! log_has "$1"; then
    fail "call not logged: [$1]; calls were: [$(cat "$FAKE_LOG" 2>/dev/null)]"
  fi
}

assert_not_called() {
  if log_has "$1"; then
    fail "call logged but should not be: [$1]"
  fi
}

# fixture <tool> <args...>: stdin becomes the fake's stdout for exactly those args.
# Sets $tool and $key for fixture_exit, so feed it with < or <<, not a pipe (a pipe runs it in a subshell). Call it again to change the world between runs.
fixture() {
  tool=$1
  shift
  key=$(mkkey "$@")
  [ -d "$FAKE_FIXTURES/$tool" ] || mkdir -p "$FAKE_FIXTURES/$tool"
  for f in "$FAKE_FIXTURES/$tool/$key".*; do
    case "${f##*/}" in "$key".out | "$key".err | "$key".exit | "$key".calls | "$key".[0-9]*) rm -f "$f" ;; esac
  done
  cat_stdin > "$FAKE_FIXTURES/$tool/$key.out"
}

# fixture_exit <status> [stderr]: the last fixture's call exits <status>, printing stderr.
fixture_exit() {
  echo "$1" > "$FAKE_FIXTURES/$tool/$key.exit"
  printf '%s\n' "${2:-}" > "$FAKE_FIXTURES/$tool/$key.err"
}

# fixture_seq <n> <tool> <args...>: stdin is the reply to the nth call with those args (see
# fake-cli); reply 1 must exist. fixture_exit then applies to reply n.
fixture_seq() {
  n=$1
  tool=$2
  shift 2
  key=$(mkkey "$@").$n
  mkdir -p "$FAKE_FIXTURES/$tool"
  cat_stdin > "$FAKE_FIXTURES/$tool/$key.out"
}

# count_calls <prefix>: how many logged calls start with <prefix>.
count_calls() {
  [ -f "$FAKE_LOG" ] || return 0
  cc_n=0
  while IFS= read -r cc_l || [ -n "$cc_l" ]; do
    case $cc_l in *"$1"*) cc_n=$((cc_n + 1)) ;; esac
  done < "$FAKE_LOG"
  echo "$cc_n"
}

# Everything piped to a fake through "-" (gh --body-file -), in call order.
fake_stdin() {
  cat "$FAKE_LOG.stdin" 2> /dev/null || :
}

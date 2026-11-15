# shellcheck shell=sh
# scripts/count-tests: one integer, the number of test_* functions in test/*_test.sh.

test_count_tests_prints_one_integer_matching_the_pattern() {
  expected=$(cd "$FACTORY_ROOT" && sed -n 's/^\(test_[A-Za-z0-9_]*\)[[:space:]]*().*/\1/p' test/*_test.sh | wc -l | tr -d ' ')
  actual=$(sh "$FACTORY_ROOT/scripts/count-tests")
  case "$actual" in
    '' | *[!0-9]*) fail "count-tests output is not a single integer: [$actual]" ;;
  esac
  assert_eq "$expected" "$actual" "test count"
}

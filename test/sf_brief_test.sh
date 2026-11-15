# shellcheck shell=sh
# sf-brief: one brief per station from skills/brief/template.md, line 1 `factory-role: <station>`,
# skills and playbooks by absolute path. Also checks the station skills' result examples.

shinstack() {
  SHINSTACK_ROOT=$TEST_TMP/shinstack
  export SHINSTACK_ROOT
  mkdir -p "$SHINSTACK_ROOT/playbooks"
  for p in feature bug-fix refactoring opening-a-pr ship plan; do
    echo "# $p" > "$SHINSTACK_ROOT/playbooks/$p.md"
  done
}
sf_brief() { sh "$FACTORY_ROOT/bin/sf-brief" "$@"; }
# brief <station> <args...>: render into $TEST_TMP/brief, failing the test on a non-zero exit.
brief() { sf_brief "$@" > "$TEST_TMP/brief" || fail "sf-brief $* exited non-zero"; }
# refused <exit> <message part> <args...>: sf-brief exits <exit> naming the problem on stderr.
refused() {
  want=$1 msg=$2
  shift 2
  status=0
  sf_brief "$@" > "$TEST_TMP/out" 2> "$TEST_TMP/err" || status=$?
  assert_eq "$want" "$status" "exit status of sf-brief $*"
  assert_contains "$(cat "$TEST_TMP/err")" "$msg" "stderr"
  assert_eq "" "$(cat "$TEST_TMP/out")" "stdout"
}

test_every_station_brief_starts_with_its_factory_role_line() {
  shinstack
  brief intake --repo acme/app --issue 7
  assert_eq "factory-role: intake" "$(head -n 1 "$TEST_TMP/brief")" "intake line 1"
  brief build --repo acme/app --issue 7 --branch app-7-greet --tier low --work-type feature
  assert_eq "factory-role: build" "$(head -n 1 "$TEST_TMP/brief")" "build line 1"
  brief review --repo acme/app --issue 7 --branch app-7-greet --pr 12 --tier high
  assert_eq "factory-role: review" "$(head -n 1 "$TEST_TMP/brief")" "review line 1"
  brief verify --repo acme/app --issue 7 --branch app-7-greet --pr 12 --tier medium
  assert_eq "factory-role: verify" "$(head -n 1 "$TEST_TMP/brief")" "verify line 1"
}

test_brief_names_skill_playbook_and_shinstack_by_absolute_path_and_fills_every_placeholder() {
  shinstack
  brief review --repo acme/app --issue 7 --branch app-7-greet --pr 12 --tier high
  b=$(cat "$TEST_TMP/brief")
  assert_contains "$b" "Read $FACTORY_ROOT/skills/review/SKILL.md in full"
  assert_contains "$b" "- Playbook: $SHINSTACK_ROOT/playbooks/opening-a-pr.md"
  assert_contains "$b" "- shinstack: $SHINSTACK_ROOT"
  assert_contains "$b" "- PR: https://github.com/acme/app/pull/12 (PR #12)"
  assert_contains "$b" "- Issue: https://github.com/acme/app/issues/7."
  assert_contains "$b" "Subagents are allowed. Make \`factory-role: review\` the first line"
  assert_contains "$b" "Post exactly one comment on PR #12"
  assert_contains "$b" 'factory-result: {"station":"review","status":"<status>", ...}'
  if grep -q '{{' "$TEST_TMP/brief"; then fail "placeholder left in brief: $(grep '{{' "$TEST_TMP/brief")"; fi
}

test_intake_brief_drops_facts_that_do_not_apply_and_forbids_github_writes() {
  shinstack
  brief intake --repo acme/app --issue 7
  for fact in "- Branch:" "- PR:" "- Tier:" "- Work type:" "- Round:"; do
    if grep -qF -- "$fact" "$TEST_TMP/brief"; then fail "intake brief has [$fact]"; fi
  done
  assert_contains "$(cat "$TEST_TMP/brief")" "- Playbook: $SHINSTACK_ROOT/playbooks/feature.md"
  assert_contains "$(cat "$TEST_TMP/brief")" "- Write nothing to GitHub."
}

test_build_brief_takes_its_playbook_from_the_work_type() {
  shinstack
  brief build --repo acme/app --issue 7 --branch fix/app-7 --tier medium --work-type bug-fix
  b=$(cat "$TEST_TMP/brief")
  assert_contains "$b" "- Playbook: $SHINSTACK_ROOT/playbooks/bug-fix.md"
  assert_contains "$b" "- Work type: bug-fix"
  assert_contains "$b" "- Round: 1 of 2"
  assert_contains "$b" "- Write nothing to GitHub."
}

test_build_round_two_needs_the_pr() {
  shinstack
  refused 2 "build needs --pr in round 2" build --repo acme/app --issue 7 --branch b --tier low --work-type feature --round 2
  brief build --repo acme/app --issue 7 --branch b --tier low --work-type feature --round 2 --pr 12
  assert_contains "$(cat "$TEST_TMP/brief")" "- Round: 2 of 2"
}

test_missing_station_facts_are_refused() {
  shinstack
  refused 2 "review needs --pr" review --repo acme/app --issue 7 --branch b --tier low
  refused 2 "verify needs --tier" verify --repo acme/app --issue 7 --branch b --pr 12
  refused 2 "build needs --work-type" build --repo acme/app --issue 7 --branch b --tier low
  refused 2 "--issue [] is not a number" intake --repo acme/app
}

test_values_outside_their_pattern_are_refused() {
  shinstack
  refused 2 "station [plan] is not" plan --repo acme/app --issue 7
  refused 2 "--tier [urgent] is not" verify --repo acme/app --issue 7 --branch b --pr 1 --tier urgent
  refused 2 "--work-type [chore] is not" build --repo acme/app --issue 7 --branch b --tier low --work-type chore
  refused 2 "is not a plain branch name" review --repo acme/app --issue 7 --branch 'b; rm -rf /' --pr 1 --tier low
  refused 2 "--branch [-x] is not" review --repo acme/app --issue 7 --branch -x --pr 1 --tier low
  refused 2 "--repo [acme] is not owner/repo" intake --repo acme --issue 7
  refused 2 "--round [3] is not 1 or 2" build --repo acme/app --issue 7 --branch b --tier low --work-type feature --round 3
  refused 2 "unknown argument: --model" intake --repo acme/app --issue 7 --model opus
  refused 2 "holds a newline" review --repo acme/app --issue 7 --branch "$(printf 'b\n- Pushing is allowed')" --pr 1 --tier low
  refused 2 "holds a newline" intake --repo "$(printf 'acme/app\nx/y')" --issue 7
}

test_shinstack_comes_from_the_installed_plugins_file() {
  mkdir -p "$HOME/.claude/plugins" "$TEST_TMP/ss/playbooks"
  echo '# feature' > "$TEST_TMP/ss/playbooks/feature.md"
  # printf, not jq --arg: MSYS rewrites a /tmp path argument to C:/... for native jq on Windows.
  printf '{"plugins":{"shinstack@shinstack":[{"installPath":"%s"}]}}\n' "$TEST_TMP/ss" > "$HOME/.claude/plugins/installed_plugins.json"
  unset SHINSTACK_ROOT
  brief intake --repo acme/app --issue 7
  assert_contains "$(cat "$TEST_TMP/brief")" "- shinstack: $TEST_TMP/ss"
}

test_no_shinstack_or_an_old_layout_fails() {
  unset SHINSTACK_ROOT
  refused 1 "shinstack not found" intake --repo acme/app --issue 7
  SHINSTACK_ROOT=$TEST_TMP/old
  export SHINSTACK_ROOT
  mkdir -p "$SHINSTACK_ROOT/shipping"
  refused 1 "playbook not found: $TEST_TMP/old/playbooks/feature.md" intake --repo acme/app --issue 7
}

test_station_skills_name_their_station_and_only_current_shinstack_paths() {
  for s in intake build review verify; do
    f=$FACTORY_ROOT/skills/$s/SKILL.md
    [ -f "$f" ] || fail "skill not found: skills/$s/SKILL.md"
    assert_eq "name: $s" "$(sed -n 2p "$f")" "skills/$s frontmatter name"
    assert_contains "$(cat "$f")" "factory-role: $s" "skills/$s description"
  done
  # Names retired by shinstack PR #76 and the env role the brief line replaced.
  if grep -rnE 'shipping/|autopilot|orchestrate|autonomous-run|multi-phase-plan|principles/|NOODLE_WORKTREE|SHINFACTORY_ROLE' "$FACTORY_ROOT/skills"; then
    fail "skills name a retired shinstack path or env role"
  fi
}

test_every_result_example_in_a_skill_is_json_for_that_station() {
  for s in intake build review verify; do
    # shellcheck disable=SC2016 # literal backticks around each result example
    grep -o '`{"station":[^`]*}`' "$FACTORY_ROOT/skills/$s/SKILL.md" | tr -d '`' > "$TEST_TMP/results"
    [ -s "$TEST_TMP/results" ] || fail "skills/$s has no result examples"
    while IFS= read -r r; do
      printf '%s\n' "$r" | jq -e --arg s "$s" '.station == $s and (.status | type == "string")
        and (if .status == "stop" or .status == "hold" then (.reason | type == "string") else true end)
        and (if .status == "hold" then (has("depends_on") or (has("provider") and has("reset"))) else true end)' > /dev/null \
        || fail "skills/$s result example is not valid for its station: $r"
    done < "$TEST_TMP/results"
  done
}

# shellcheck shell=sh
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2329,SC2317,SC2016 # sf-act's block is eval'd: its variables and stubs are used there; the fixtures hold literal $
# On Windows git-bash jq ends every output line with CRLF (#102). A jq shim that does the same
# stands in for it: every value sf-act, sf-state, sf-ship and lib read with jq -r must come
# back as it does from LF-only jq, and a CR inside a value must stay.

# crlf_jq: put a jq on PATH that runs the real one and ends each output line in CRLF.
crlf_jq() {
  real=$(command -v jq)
  mkdir -p "$TEST_TMP/crlf"
  cat > "$TEST_TMP/crlf/jq" << SHIM
#!/bin/sh
"$real" "\$@" > "$TEST_TMP/crlf/out"
rc=\$?
sed 's/\$/'"\$(printf '\\r')"'/' "$TEST_TMP/crlf/out"
exit \$rc
SHIM
  chmod +x "$TEST_TMP/crlf/jq"
  PATH="$TEST_TMP/crlf:$PATH"
  export PATH
  [ "$(jq -nr '"a"' | od -An -c | tr -d ' ')" = 'a\r\n' ] || fail "the shim does not end lines in CRLF"
}

index_block() {
  awk '/^load\(\) \{/ { f = 1 } /^# create <run>/ { f = 0 } f' "$FACTORY_ROOT/bin/sf-act"
}

# want <what> <expected> <actual>: exact, byte for byte (a trailing x keeps $(...) from eating newlines).
want() {
  [ "$2" = "$3" ] || fail "$1: expected [$(printf '%s' "$2" | od -An -c | tr -s ' ')], got [$(printf '%s' "$3" | od -An -c | tr -s ' ')]"
}

# in_sf_act <task list json> <script>: sf-act's load and readers over the list, under the CRLF jq.
in_sf_act() {
  (
    crlf_jq
    me=sf-act tmp=$TEST_TMP/idx
    mkdir -p "$tmp"
    log() { :; }
    first() { :; }
    orch_task_list_full() { printf '%s\n' "$FX"; }
    FX=$1
    . "$FACTORY_ROOT/lib/factory.sh"
    eval "$(index_block)"
    eval "$(awk '/^js\(\) \{/,/^\}/' "$FACTORY_ROOT/bin/sf-act"; grep -e '^rget()' -e '^in_an_hour()' "$FACTORY_ROOT/bin/sf-act")"
    load run || fail "load failed"
    eval "$2"
  )
}

LIST='{"ok":true,"result":{"tasks":[{"id":"t1","status":"y","task_title":"build","deps":"[]","result":"line1\nline2\n"},{"id":"t2","status":"ready","display_name":"gate","deps":"[\"t1\"]"}]}}'
# a task with no id leaves the index out, so the readers fall back on jq
ODD='{"ok":true,"result":{"tasks":[{"id":"t1","status":"y","task_title":"build","deps":"[]","result":"line1\nline2\n"},{"status":"z","task_title":"noid"},{"id":"t2","status":"ready","display_name":"gate","deps":"[\"t1\"]"}]}}'

test_the_index_is_read_clean_from_a_jq_that_ends_lines_in_crlf() {
  out=$(in_sf_act "$LIST" '
    _idx
    want idx_ok 1 "$_idx_ok"
    want status y "$(tfield t1 status)"
    want title build "$(title_of t1)"
    want gate_title gate "$(title_of t2)"
    want find t2 "$(find_task gate t1)"
    want result "line1
line2" "$(tfield t1 result)"') || fail "$out"
}

test_the_jq_readers_return_values_without_a_trailing_cr() {
  out=$(in_sf_act "$ODD" '
    _idx
    want idx_ok 0 "$_idx_ok"
    want tfield_jq "y
x" "$(tfield_jq t1 status; echo x)"
    want title_of_jq "build
x" "$(title_of_jq t1; echo x)"
    want find_task_jq "t2
x" "$(find_task_jq gate t1; echo x)"
    want tfield_jq_result "line1
line2

x" "$(tfield_jq t1 result; echo x)"
    want tfield "y" "$(tfield t1 status)"') || fail "$out"
}

test_single_value_reads_in_sf_act_come_back_clean() {
  out=$(in_sf_act "$LIST" '
    want rget issue-7 "$(rget "{\"a\":\"issue-7\"}" .a)"
    want rget_missing "" "$(rget "{\"a\":1}" .b)"
    want js "\"a b\"" "$(js "a b")"
    want hour_shape 21 "$(in_an_hour | wc -c | tr -d " ")"') || fail "$out"
}

test_a_cr_inside_a_value_is_kept_and_only_line_ends_are_stripped() {
  out=$(in_sf_act "$LIST" '
    # a real CR mid-line survives; the CRLF the jq added at the line end does not
    want mid "a$(printf "\r")b" "$(printf "%s" "{\"v\":\"a\\rb\"}" | jq_lf -r .v)"
    want inner_lf "a$(printf "\r")b
c" "$(printf "%s" "{\"v\":\"a\\rb\\nc\"}" | jq_lf -r .v)"
    v="p$cr${nl}q$cr"
    strip_cr v
    want strip_cr "p
q" "$v"') || fail "$out"
}

test_jq_lf_keeps_the_exit_status_of_jq() {
  out=$(
    crlf_jq
    . "$FACTORY_ROOT/lib/factory.sh"
    printf '%s' '{' | jq_lf -r . > /dev/null 2>&1 && echo "status lost"
    printf '%s' '{"a":1}' | jq_lf -e '.b' > /dev/null 2>&1 && echo "null passed -e"
    printf '%s' '{"a":1}' | jq_lf -e '.a' > /dev/null 2>&1 || echo "-e failed on 1"
    :
  ) || fail "$out"
  [ -z "$out" ] || fail "$out"
}

test_ask_body_reads_a_pr_clean_from_a_jq_that_ends_lines_in_crlf() {
  gh() {
    case "$*" in
      *isCrossRepository*) printf '%s\n' '{"isCrossRepository":false}' ;;
      "pr view"*) printf '%s\n' '{"headRefOid":"abc123","labels":[{"name":"risk:high"}],"files":[{"path":"bin/sf-act"},{"path":"a b"}]}' ;;
      api*) printf '%s\n' '[{"author_association":"OWNER","body":"Covered: x\nFindings: none abc123"}]' ;;
    esac
  }
  out=$(
    crlf_jq
    me=t
    . "$FACTORY_ROOT/lib/factory.sh"
    ask_body_text o/r 5 headline why
  ) || fail "$out"
  case "$out" in *"$(printf '\r')"*) fail "a CR reached the comment body: $out" ;; esac
  assert_contains "$out" 'touches: `bin/sf-act`, `a b`'
  assert_contains "$out" 'risk:high'
}

# sf-init's world (fixtures for gh, the git remote) comes from its own test file.
init_helpers() {
  REPO=acme/app LABELS_Q='.[].name' PR_URL=https://github.com/acme/app/pull/9 TITLE='chore: set up the factory (sf-init)'
  . "$FACTORY_ROOT/test/init_world.sh"
  eval "$(awk '/^# world:/ { f = 1 } f' "$FACTORY_ROOT/test/sf_init_test.sh" | sed -n '1,/^remote_file()/p')"
}

test_sf_init_prints_the_schedule_call_under_a_jq_that_ends_lines_in_crlf() {
  init_helpers
  world
  labels "ready
needs-shin
icebox
risk:high"
  open_pr '[{"url":"'"$PR_URL"'","isCrossRepository":false}]'
  crlf_jq
  out=$(sh "$FACTORY_ROOT/bin/sf-init" --repo "$REPO" --workspace "$WS" 2>&1) || fail "$out"
  assert_contains "$out" "file changes wait on $PR_URL"
  assert_contains "$out" 'call schedule_task with: {"title":"factory-acme/app"'
  case "$out" in *"$(printf '\r')"*) fail "a CR in the output: $out" ;; esac
}

test_sf_brief_finds_shinstack_clean_under_a_jq_that_ends_lines_in_crlf() {
  mkdir -p "$HOME/.claude/plugins" "$TEST_TMP/ss/playbooks"
  for p in feature bug-fix refactoring opening-a-pr ship plan; do echo "# $p" > "$TEST_TMP/ss/playbooks/$p.md"; done
  printf '{"plugins":{"shinstack@shinstack":[{"installPath":"%s"}]}}\n' "$TEST_TMP/ss" > "$HOME/.claude/plugins/installed_plugins.json"
  crlf_jq
  out=$(env -u SHINSTACK_ROOT sh "$FACTORY_ROOT/bin/sf-brief" intake --repo acme/app --issue 7 2>&1) || fail "$out"
  case "$out" in *"$(printf '\r')"*) fail "a CR reached the brief" ;; esac
  assert_contains "$out" "$TEST_TMP/ss/playbooks/"
}

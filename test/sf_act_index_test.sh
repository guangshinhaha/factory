# shellcheck shell=sh
# shellcheck disable=SC2034,SC2154,SC2329,SC2317,SC2016 # sf-act's block is eval'd: its variables and stubs are used there; the fixtures hold literal $ and backticks
# sf-act's task index: tfield, title_of and find_task answer from a shell index that load writes,
# and must answer exactly what the jq readers (tfield_jq, title_of_jq, find_task_jq) answer from
# the same task list, for every id, title and parent, including shapes the index falls back on.

# index_block: sf-act's load, the index readers and their jq twins, cut out of the script.
index_block() {
  awk '/^load\(\) \{/ { f = 1 } /^# create <run>/ { f = 0 } f' "$FACTORY_ROOT/bin/sf-act"
}

# same_answers <name> <task-list json> <want _idx_ok>
same_answers() {
  (
    me=sf-act tmp=$TEST_TMP/idx
    mkdir -p "$tmp"
    log() { :; }
    first() { :; }
    o() { printf '%s\n' "$FX"; }
    FX=$2
    eval "$(index_block)"
    load run || { echo "load failed"; exit 1; }
    _idx
    [ "$_idx_ok" = "$3" ] || { echo "$1: _idx_ok $_idx_ok, want $3"; exit 1; }
    ids=$(printf '%s\n' "$FX" | jq -r '.result.tasks[]? | .id? // empty | tostring')
    titles=$(printf '%s\n' "$FX" | jq -r '.result.tasks[]? | (.task_title? // .display_name? // empty) | tostring')
    for id in $ids nope; do
      for f in status result; do
        [ "$(tfield "$id" $f; echo x)" = "$(tfield_jq "$id" $f; echo x)" ] || { echo "$1: tfield $id $f differs"; exit 1; }
      done
      [ "$(title_of "$id"; echo x)" = "$(title_of_jq "$id"; echo x)" ] || { echo "$1: title_of $id differs"; exit 1; }
    done
    for t in $titles nope; do
      for p in "" $ids nope; do
        [ "$(find_task "$t" "$p"; echo x)" = "$(find_task_jq "$t" "$p"; echo x)" ] || { echo "$1: find_task $t $p differs"; exit 1; }
      done
    done
  )
}

test_the_index_answers_what_jq_answers() {
  out=$(same_answers plain '{"ok":true,"result":{"tasks":[{"id":"t1","status":"completed","task_title":"intake","deps":"[]","result":"{\"body\":\"a\\nb\\n\"}"},{"id":"t2","status":"ready","display_name":"plan","deps":"[\"t1\"]"},{"id":"t3","status":"ready","task_title":"build","deps":"[\"t2\"]"},{"id":"t4","status":"x","task_title":"build","deps":"[\"t2\",\"t9\"]"},{"id":"t5","status":"y","task_title":"build","deps":"[\"t2\"]"}]}}' 1 2>&1) || fail "$out"
  out=$(same_answers empty '{"ok":true,"result":{"tasks":[]}}' 1 2>&1) || fail "$out"
}

test_a_list_with_shell_metacharacters_is_answered_the_same_and_runs_nothing() {
  list='{"ok":true,"result":{"tasks":[{"id":"$(touch${IFS}PWNED)","status":"`id`","task_title":"*","deps":"[\"*\"]","result":"$HOME \\ \" '"'"'x\n\n"},{"id":"g","task_title":"*","deps":"[\"$(touch${IFS}PWNED)\",\"a*\"]"},{"id":"it'"'"'s","task_title":"q'"'"'r","deps":"[]"}]}}'
  out=$(cd "$TEST_TMP" && same_answers meta "$list" 1 2>&1) || fail "$out"
  if [ -e "$TEST_TMP/PWNED" ] || [ -e PWNED ]; then fail "a task id ran as a command"; fi
}

test_shapes_the_index_cannot_hold_fall_back_to_jq_with_the_same_answers() {
  out=$(same_answers duplicate-id '{"ok":true,"result":{"tasks":[{"id":"d","status":"s","task_title":"t"},{"id":"d","status":"s2","task_title":"t"}]}}' 0 2>&1) || fail "$out"
  out=$(same_answers odd-types '{"ok":true,"result":{"tasks":[{"id":"n","task_title":5,"status":3,"result":[1,2]},{"status":"s","task_title":"noid"}]}}' 0 2>&1) || fail "$out"
  out=$(same_answers odd-deps '{"ok":true,"result":{"tasks":[{"id":"a","task_title":"x","deps":"not json"},{"id":"b","task_title":"x","deps":"[\"a\"]"},{"id":"c","task_title":"x","deps":"\"abc\""}]}}' 0 2>&1) || fail "$out"
  out=$(same_answers spaced '{"ok":true,"result":{"tasks":[{"id":"a b","task_title":"x y","deps":"[\"p q\"]"}]}}' 0 2>&1) || fail "$out"
  out=$(same_answers nul '{"ok":true,"result":{"tasks":[{"id":"u","status":"s","task_title":"t\u0000z"}]}}' 0 2>&1) || fail "$out"
}

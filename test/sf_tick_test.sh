# shellcheck shell=sh
# shellcheck disable=SC2016 # jq programs in single quotes
# sf-tick: the host-wide lock, sf-state, and spawning sf-act, in the world of test/act_world.sh.

# shellcheck source=test/act_world.sh
. "$FACTORY_ROOT/test/act_world.sh"

tick_world() {
  world
  FACTORY_TICK_LOCK=$TEST_TMP/tick.lock
  export FACTORY_TICK_LOCK
}
# tick: one sf-tick; stdout in $TEST_TMP/tick.out, exit status in $tick_status.
tick() {
  tick_status=0
  sh "$FACTORY_ROOT/bin/sf-tick" "$REPO" > "$TEST_TMP/tick.out" 2>&1 || tick_status=$?
}
terminals() { sim '.terminals | length' 2> /dev/null || echo 0; }
# spawned: run the command sf-tick gave the last Orca terminal, as the terminal would.
spawned() { sh -c "$(sim '.terminals[-1].command')" > "$TEST_TMP/act.out" 2>&1; }
# age <dir> <minutes>: backdate the dir.
age() { touch -t "$(date -r "$(($(date +%s) - $2 * 60))" +%Y%m%d%H%M.%S 2> /dev/null || date -d "@$(($(date +%s) - $2 * 60))" +%Y%m%d%H%M.%S)" "$1"; }

test_actions_spawn_sf_act_in_an_orca_terminal_and_keep_the_lock() {
  tick_world
  tick
  assert_eq 1 "$tick_status" "sf-tick exit status"
  assert_contains "$(cat "$TEST_TMP/tick.out")" "spawned sf-act for 1 action(s) in acme/app"
  assert_eq 1 "$(terminals)" "terminals"
  cmd=$(sim '.terminals[0].command')
  assert_contains "$cmd" "sh '$FACTORY_ROOT/bin/sf-act' --repo 'acme/app' --lock '$FACTORY_TICK_LOCK'"
  assert_contains "$cmd" "PATH='$FACTORY_ROOT/bin:$PATH' sh"
  assert_contains "$(sim '.terminals[0].worktree')" "path:"
  [ -d "$FACTORY_TICK_LOCK" ] || fail "lock released after a spawn"
  # The spawned sf-act acts, then releases the lock.
  spawned
  assert_eq 1 "$(runs_count)" "Runs"
  [ ! -e "$FACTORY_TICK_LOCK" ] || fail "lock kept after sf-act exited"
}

test_nothing_to_do_releases_the_lock_and_spawns_nothing() {
  tick_world
  issues '[]'
  tick
  assert_eq 1 "$tick_status" "sf-tick exit status"
  assert_contains "$(cat "$TEST_TMP/tick.out")" "nothing to do for acme/app"
  assert_eq 0 "$(terminals)" "terminals"
  [ ! -e "$FACTORY_TICK_LOCK" ] || fail "lock kept"
}

test_a_live_holder_blocks_the_tick_before_sf_state() {
  tick_world
  mkdir "$FACTORY_TICK_LOCK"
  echo $$ > "$FACTORY_TICK_LOCK/pid"
  tick
  assert_eq 1 "$tick_status" "sf-tick exit status"
  assert_contains "$(cat "$TEST_TMP/tick.out")" "another tick holds"
  assert_eq 0 "$(count_calls 'gh issue list')" "sf-state calls"
  assert_eq "$$" "$(cat "$FACTORY_TICK_LOCK/pid")" "lock pid"
}

test_a_fresh_lock_without_a_pid_blocks_and_an_old_one_is_taken_over() {
  tick_world
  mkdir "$FACTORY_TICK_LOCK"
  tick
  assert_contains "$(cat "$TEST_TMP/tick.out")" "another tick holds"
  age "$FACTORY_TICK_LOCK" 5
  tick
  assert_contains "$(cat "$TEST_TMP/tick.out")" "removed a stale lock"
  assert_eq 1 "$(terminals)" "terminals"
}

test_a_dead_holder_is_reaped() {
  tick_world
  mkdir "$FACTORY_TICK_LOCK"
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  echo "$dead" > "$FACTORY_TICK_LOCK/pid"
  tick
  assert_contains "$(cat "$TEST_TMP/tick.out")" "removed a stale lock"
  assert_eq 1 "$(terminals)" "terminals"
}

test_a_lock_older_than_three_hours_is_taken_over_whatever_its_pid() {
  tick_world
  mkdir "$FACTORY_TICK_LOCK"
  echo $$ > "$FACTORY_TICK_LOCK/pid"
  age "$FACTORY_TICK_LOCK" 200
  tick
  assert_contains "$(cat "$TEST_TMP/tick.out")" "removed a stale lock"
}

test_sf_state_failing_releases_the_lock() {
  tick_world
  fixture gh issue list -R "$REPO" --state open --limit 1000 --json number,labels,body < /dev/null
  fixture_exit 1 "HTTP 502"
  tick
  assert_eq 1 "$tick_status" "sf-tick exit status"
  assert_contains "$(cat "$TEST_TMP/tick.out")" "sf-state failed; nothing done"
  [ ! -e "$FACTORY_TICK_LOCK" ] || fail "lock kept"
}

test_a_failed_spawn_releases_the_lock() {
  tick_world
  orca_fails create "terminal: no window"
  tick
  assert_contains "$(cat "$TEST_TMP/tick.out")" "sf-act not spawned"
  [ ! -e "$FACTORY_TICK_LOCK" ] || fail "lock kept"
}

test_two_concurrent_ticks_spawn_one_sf_act() {
  tick_world
  sh "$FACTORY_ROOT/bin/sf-tick" "$REPO" > "$TEST_TMP/a.out" 2>&1 &
  a=$!
  sh "$FACTORY_ROOT/bin/sf-tick" "$REPO" > "$TEST_TMP/b.out" 2>&1 &
  b=$!
  wait "$a" || :
  wait "$b" || :
  assert_eq 1 "$(terminals)" "terminals"
  # The loser either found the lock held or ran after the winner's sf-act and found no work;
  # which one depends on timing (a fast runner finishes the first tick before the second starts).
  assert_eq 1 "$(cat "$TEST_TMP/a.out" "$TEST_TMP/b.out" | grep -c 'spawned sf-act')" \
    "ticks that spawned sf-act (a: $(cat "$TEST_TMP/a.out"); b: $(cat "$TEST_TMP/b.out"); terminals: $(sim -c '.terminals'))"
}

# Done when (#7): two concurrent fires plus a kill mid-Run produce one Run. sf-act is killed
# (SIGKILL: no trap runs) while creating the route task; the lock keeps a dead pid. The next tick
# reaps it, and the respawned sf-act finishes the Run it started instead of starting another.
test_concurrent_fires_and_a_kill_mid_run_leave_one_run() {
  tick_world
  # orca blocks on the first route task-create until killed.
  cat > "$TEST_TMP/bin/orca" <<EOF
#!/bin/sh
case " \$* " in
  *" task-create "*"--task-title route "*)
    if [ ! -e "$TEST_TMP/blocked-once" ]; then
      echo \$\$ > "$TEST_TMP/blocked-once"
      exec sleep 60
    fi
    ;;
esac
exec sh "$FACTORY_ROOT/test/fakes/orca-sim" "\$@"
EOF
  sh "$FACTORY_ROOT/bin/sf-tick" "$REPO" > "$TEST_TMP/a.out" 2>&1 &
  a=$!
  sh "$FACTORY_ROOT/bin/sf-tick" "$REPO" > "$TEST_TMP/b.out" 2>&1 &
  b=$!
  wait "$a" || :
  wait "$b" || :
  assert_eq 1 "$(terminals)" "terminals after two concurrent fires"
  sh -c "$(sim '.terminals[0].command')" > "$TEST_TMP/act.out" 2>&1 &
  act_pid=$!
  i=0
  while [ ! -s "$TEST_TMP/blocked-once" ] && [ $i -lt 300 ]; do i=$((i + 1)); sleep 0.1; done
  [ -s "$TEST_TMP/blocked-once" ] || fail "sf-act never reached the route task-create: $(cat "$TEST_TMP/act.out")"
  pid=$(cat "$FACTORY_TICK_LOCK/pid")
  kill -9 "$pid" "$(cat "$TEST_TMP/blocked-once")" 2> /dev/null || :
  kill -9 "$act_pid" 2> /dev/null || :
  wait "$act_pid" 2> /dev/null || :
  [ -d "$FACTORY_TICK_LOCK" ] || fail "lock removed by a killed sf-act"
  assert_eq 1 "$(runs_count)" "Runs after the kill"
  assert_eq none "$(status_of route)" "route after the kill"
  # Next fire: the dead holder is reaped and sf-act picks the Run up.
  tick
  assert_contains "$(cat "$TEST_TMP/tick.out")" "removed a stale lock"
  spawned
  assert_eq 1 "$(runs_count)" "Runs"
  assert_eq 1 "$(count_titled intake)" "intake tasks"
  assert_eq 1 "$(count_titled route)" "route tasks"
  assert_eq dispatched "$(status_of intake)" "intake"
  [ ! -e "$FACTORY_TICK_LOCK" ] || fail "lock kept after the respawned sf-act: $(cat "$TEST_TMP/act.out")"
}

test_a_lock_a_late_sf_act_claimed_during_the_tick_is_not_released() {
  tick_world
  mkdir "$FACTORY_TICK_LOCK"
  age "$FACTORY_TICK_LOCK" 5
  sleep 300 &
  late=$!
  # sf-state's first gh call: the late sf-act of the taken-over lock claims the new one.
  cat > "$TEST_TMP/bin/gh" <<W
#!/bin/sh
[ -f "$FACTORY_TICK_LOCK/pid" ] || (set -C; echo $late > "$FACTORY_TICK_LOCK/pid") 2> /dev/null
exec sh "$FACTORY_ROOT/test/fakes/gh" "\$@"
W
  chmod +x "$TEST_TMP/bin/gh"
  issues '[]'
  tick
  rm -f "$TEST_TMP/bin/gh"
  assert_contains "$(cat "$TEST_TMP/tick.out")" "nothing to do"
  assert_eq "$late" "$(cat "$FACTORY_TICK_LOCK/pid" 2> /dev/null)" "pid in the lock"
  issues "[$(jq -cn '{number: 7, labels: [{name: "ready"}], body: "x"}')]"
  tick
  kill "$late"
  assert_contains "$(cat "$TEST_TMP/tick.out")" "another tick holds"
  assert_eq 0 "$(terminals)" "terminals"
}

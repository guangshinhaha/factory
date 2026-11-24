# shellcheck shell=sh
# shellcheck disable=SC2016,SC2034 # jq programs in single quotes; constants used by the test files
# The act world (test/act_world.sh) on the T3 orchestrator: FACTORY_ORCH=t3, issue comments in a
# stateful fake gh (test/fakes/gh-sim), the T3 thread snapshot in $FACTORY_T3_THREADS, the foreman's
# requests in $FACTORY_T3_REQUESTS. No orca on PATH but the guard, so any orca call fails the test.
# The act world's state helpers (status_of, finish, escalation, ...) are redefined to read the
# markers and write what the foreman would. Sourced by test/orch_t3_test.sh.

# shellcheck source=test/act_world.sh
. "$FACTORY_ROOT/test/act_world.sh"

THREADS=
REQUESTS=

t3_world() {
  world
  rm -f "$TEST_TMP/bin/orca"
  GH_SIM=$TEST_TMP/ghsim
  mkdir -p "$GH_SIM"
  printf '#!/bin/sh\n. "%s/test/fakes/gh-sim"\n' "$FACTORY_ROOT" > "$TEST_TMP/bin/gh"
  chmod +x "$TEST_TMP/bin/gh"
  THREADS=$TEST_TMP/threads.json
  REQUESTS=$TEST_TMP/requests.jsonl
  echo '{"threads":[]}' > "$THREADS"
  FACTORY_ORCH=t3 FACTORY_T3_THREADS=$THREADS FACTORY_T3_REQUESTS=$REQUESTS
  export GH_SIM FACTORY_ORCH FACTORY_T3_THREADS FACTORY_T3_REQUESTS
}

# t3_q <jq filter> [jq args...]: the filter over the folded markers, read the way lib/orch-t3.sh
# reads them (a fresh read, unlogged).
t3_q() {
  (
    f=$1
    shift
    unset FACTORY_T3_CACHE
    GH_SIM_QUIET=1
    export GH_SIM_QUIET
    repo=$REPO
    tmp=$TEST_TMP/q
    rm -rf "$tmp" && mkdir -p "$tmp"
    # shellcheck source=lib/orch-t3.sh
    . "$FACTORY_ROOT/lib/orch-t3.sh"
    t3_records && t3_jq -r "$@" "$T3_DEFS fold | $f" | tr -d '\r'
  )
}

status_of() { t3_q '[.tasks[] | select(.title == $t)] | last | .status // "none"' --arg t "$1"; }
id_of() { t3_q '[.tasks[] | select(.title == $t)] | last | .id // ""' --arg t "$1"; }
spec_of() { t3_q '[.tasks[] | select(.title == $t)] | last | .spec // ""' --arg t "$1"; }
count_titled() { t3_q '[.tasks[] | select(.title == $t)] | length' --arg t "$1"; }
runs_count() { t3_q '.runs | length'; }
dispatch_of() { t3_q '[.tasks[] | select(.title == $t)] | last | .dispatch // ""' --arg t "$1"; }
agent_of() { t3_q '. as $s | [.tasks[] | select(.title == $t)] | last | $s.disp[.dispatch] | "\(.agent)/\(.model)"' --arg t "$1"; }
worktree_of() { t3_q '. as $s | [.tasks[] | select(.title == $t)] | last | $s.disp[.dispatch].worktree' --arg t "$1"; }
dispatch_count() { t3_q '[.disp[] | select(.task == $t)] | length' --arg t "$1"; }
wt_path() { git -C "$TEST_TMP/app" worktree list --porcelain | awk '/^worktree / { w = substr($0, 10) } $0 == "branch refs/heads/app-7" { print w }'; }

# comment_as <author> <issue> <marker json>: a comment ending in the marker, straight into the store.
comment_as() {
  jq -cn --arg a "$1" --arg n "$2" --arg m "$3" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{issue_url: "https://api.github.com/repos/acme/app/issues/\($n)", author_association: $a, body: "factory: x\n\n<!-- factory:\($m) -->", created_at: $at}' \
    >> "$GH_SIM/comments.jsonl"
}
# result_marker <dispatch> <body> [outcome]: the foreman's result marker for a finished thread.
result_marker() {
  comment_as OWNER 7 "$(jq -rcn --arg d "$1" --arg b "$2" --arg o "${3:-succeeded}" '{kind: "result", dispatch: $d, outcome: $o, body: $b} | tojson | gsub(">"; "\\u003e")')"
}
# thread <dispatch> <status> [updatedAt] [lastMessage]: the dispatch's thread in the snapshot, as
# the foreman lists it (title ends with [<dispatch>]).
thread() {
  th_new=$(jq --arg d "$1" --arg s "$2" --arg u "${3:-2026-11-02T00:00:00Z}" --arg l "${4:-}" \
    '.threads |= (map(select(.title | endswith("[\($d)]") | not)) + [{id: "thr-\($d)", title: "acme/app#7 x [\($d)]", status: $s, updatedAt: $u, lastMessage: $l}])' "$THREADS") || return 1
  printf '%s\n' "$th_new" > "$THREADS"
}
# finish <title> <body> [outcome]: the dispatched worker reported; the foreman posts its result.
finish() {
  fd=$(dispatch_of "$1")
  [ -n "$fd" ] || fail "no dispatch for $1"
  thread "$fd" completed
  result_marker "$fd" "$2" "${3:-succeeded}"
}
# escalation <title> <at>: the T3 form of Orca's "stopped without reporting": the thread's turn
# ended at <at> and no result was posted.
escalation() { thread "$(dispatch_of "$1")" completed "$2"; }
# agent_ended <status>: the review thread ended with that status, no result.
agent_ended() { thread "$(dispatch_of review)" "$1"; }
# run_done: every task completed (status markers, as sf-act writes them) and the issue closed.
run_done() {
  for rd_t in $(t3_q '.tasks[] | select(.status != "completed") | .id'); do
    comment_as OWNER 7 "{\"kind\":\"status\",\"task\":\"$rd_t\",\"status\":\"completed\"}"
  done
  issues '[]'
}
# requests_of <kind>: the request lines of that kind the foreman got.
requests_of() { jq -c --arg k "$1" 'select(has($k))' "$REQUESTS" 2> /dev/null | tr -d '\r'; }
no_orca_called() { assert_eq 0 "$(grep -c '^orca ' "$FAKE_LOG")" "orca calls"; }

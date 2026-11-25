# shellcheck shell=sh
# shellcheck disable=SC2016,SC2034 # jq programs in single quotes; constants used by the test files
# A world for multi-fire tests of sf-act: real sf-state and sf-brief against issue comments in a
# stateful fake gh (test/fakes/gh-sim), the T3 thread snapshot in $THREADS and the foreman's requests
# in $REQUESTS; sf-ship, sf-stop and sf-hold are stubs that log their arguments. The checkout is a
# real git clone of a local bare origin. The helpers read the markers and write what the foreman would.
# Repo acme/app, issue 7, branch app-7, PR 12. Sourced by test/sf_act_test.sh and orch_t3_test.sh.

REPO=acme/app
READY_EVENT='{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"}'
GO='factory-result: {"station":"intake","status":"go","tier":"low","work_type":"feature","plan_first":false}'
PLAN_FIRST='factory-result: {"station":"intake","status":"go","tier":"high","work_type":"feature","plan_first":true}'
BUILT='factory-result: {"station":"build","status":"built","head_sha":"abc","commits":1,"checks":"ok"}'
CLEAN='factory-result: {"station":"review","status":"clean","head_sha":"abc","comment_url":"u"}'
VERIFIED='factory-result: {"station":"verify","status":"PASS","verdict":"PASS","head_sha":"abc","comment_url":"u"}'
THREADS=
REQUESTS=

git_q() { git -c init.defaultBranch=main "$@" > /dev/null 2>&1; }

# stub <name>: a logging stand-in for a sibling sf-* script. Prints $TEST_TMP/<name>.out and
# exits with $TEST_TMP/<name>.exit (default 0).
stub() {
  cat_stdin > "$TEST_TMP/bin/$1" <<STUB
#!/bin/sh
printf '%s\n' "$1 \$*" >> "\$FAKE_LOG"
FAKE_CLI_LIB=1 . "\$FACTORY_ROOT/test/fakes/fake-cli"
if [ -f "\$TEST_TMP/$1.out" ]; then cat_stdin < "\$TEST_TMP/$1.out"; fi
n=0
{ read -r n; } 2> /dev/null < "\$TEST_TMP/$1.exit" || n=0
exit "\$n"
STUB
}

# act_world_repos <dir>: <dir>/origin.git (bare) and <dir>/app (clone on main, CLAUDE.md pushed); cd into app.
# test/run builds one in $ACT_WORLD_TEMPLATE for world() to copy.
act_world_repos() {
  git_q init --bare "$1/origin.git"
  git -C "$1/origin.git" symbolic-ref HEAD refs/heads/main
  git_q clone "$1/origin.git" "$1/app"
  cd "$1/app" || fail "checkout not entered"
  git_q checkout -b main
  printf '# app\n\nshinstack-mode: auto\nfactory-concurrency: 2\n' > CLAUDE.md
  git add CLAUDE.md && git_q commit -m init && git_q push -u origin main
  git_q remote set-head origin -a
}

# world: issue 7 is ready and has no Run; origin/main has CLAUDE.md; the checkout is main.
world() {
  FAKE_FIXTURES=$TEST_TMP/fx
  GH_SIM=$TEST_TMP/ghsim
  THREADS=$TEST_TMP/threads.json
  REQUESTS=$TEST_TMP/requests.jsonl
  FACTORY_T3_THREADS=$THREADS FACTORY_T3_REQUESTS=$REQUESTS
  SHINSTACK_ROOT=$TEST_TMP/shinstack
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  FACTORY_ACT_LOG=$TEST_TMP/act.log
  export FACTORY_ACT_LOG FAKE_FIXTURES GH_SIM FACTORY_T3_THREADS FACTORY_T3_REQUESTS SHINSTACK_ROOT GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  mkdir -p "$FAKE_FIXTURES/gh" "$FAKE_FIXTURES/gantry-gate-evidence" "$GH_SIM/fail" "$TEST_TMP/bin" "$SHINSTACK_ROOT/playbooks"
  for p in feature bug-fix refactoring opening-a-pr ship plan; do echo "# $p" > "$SHINSTACK_ROOT/playbooks/$p.md"; done
  echo '{"threads":[]}' > "$THREADS"
  printf '#!/bin/sh\n. "%s/test/fakes/gh-sim"\n' "$FACTORY_ROOT" > "$TEST_TMP/bin/gh"
  stub sf-ship
  stub sf-stop
  stub sf-hold
  chmod +x "$TEST_TMP/bin/gh" "$TEST_TMP/bin/sf-ship" "$TEST_TMP/bin/sf-stop" "$TEST_TMP/bin/sf-hold"
  PATH=$TEST_TMP/bin:$PATH
  export PATH

  if [ -d "${ACT_WORLD_TEMPLATE:-}/app" ]; then
    # test/run built the repos once; a copy plus one config rewrite is cheaper than seven git runs.
    cp -R "$ACT_WORLD_TEMPLATE/origin.git" "$ACT_WORLD_TEMPLATE/app" "$TEST_TMP/"
    repoint_origin "$TEST_TMP/app" "$TEST_TMP/origin.git"
    cd "$TEST_TMP/app" || fail "checkout not entered"
  else
    act_world_repos "$TEST_TMP"
  fi

  issues '[{"number":7,"labels":[{"name":"ready"}],"body":"Done when: it greets"}]'
  prs '[]'
  timeline "[$READY_EVENT]"
  echo ready | fixture gh issue view 7 -R "$REPO" --json labels -q '[.labels[].name] | join(",")'
  echo "Greet people" | fixture gh issue view 7 -R "$REPO" --json title -q .title
  open_pr app-7 ''
  open_pr debrief-app-7 ''
}

issues() { printf '%s\n' "$1" | fixture gh issue list -R "$REPO" --state open --limit 1000 --json number,labels,body; }
prs() { printf '%s\n' "$1" | fixture gh pr list -R "$REPO" --state open --limit 1000 --json number,headRefName,isCrossRepository; }
timeline() { printf '%s\n' "$1" | fixture gh api "repos/$REPO/issues/7/timeline" --paginate; }
# open_pr <branch> <number or empty>: sf-act's `gh pr list --head` lookup (the fake skips -q).
open_pr() { printf '%s\n' "$2" | fixture gh pr list -R "$REPO" --head "$1" --state open --json number -q '.[0].number // empty'; }
# marker_comment <json> <created_at>: an OWNER comment carrying a factory marker.
marker_comment() { jq -cn --arg m "$1" --arg at "$2" '{event: "commented", author_association: "OWNER", body: "factory: x\n\n<!-- factory:\($m) -->", created_at: $at}'; }

# act: one sf-act fire; stdout/stderr in $TEST_TMP/out and err, exit status in $act_status. As with the
# foreman, each fire gets a new request file; its lines are then added to $REQUESTS, so a request
# repeated by a later fire shows up twice.
act() {
  act_status=0
  rm -f "$TEST_TMP/fire.jsonl"
  FACTORY_T3_REQUESTS=$TEST_TMP/fire.jsonl sh "$FACTORY_ROOT/bin/sf-act" --repo "$REPO" > "$TEST_TMP/out" 2> "$TEST_TMP/err" || act_status=$?
  if [ -f "$TEST_TMP/fire.jsonl" ]; then cat "$TEST_TMP/fire.jsonl" >> "$REQUESTS"; fi
}
acts() {
  act
  assert_status0 "$act_status" "sf-act exit status" "$TEST_TMP/err"
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
# escalation <title> <at> [lastMessage]: the worker stopped without reporting: its thread's turn
# ended at <at> and no result was posted.
escalation() { thread "$(dispatch_of "$1")" completed "$2" "${3:-}"; }
# agent_ended <status> [lastMessage]: the review thread ended with that status, no result.
agent_ended() { thread "$(dispatch_of review)" "$1" 2026-11-02T00:00:00Z "${2:-}"; }
# run_done: every task completed (status markers, as sf-act writes them) and the issue closed.
run_done() {
  for rd_t in $(t3_q '.tasks[] | select(.status != "completed") | .id'); do
    comment_as OWNER 7 "{\"kind\":\"status\",\"task\":\"$rd_t\",\"status\":\"completed\"}"
  done
  issues '[]'
}
# posted_of <marker kind>: the text of the posted comments carrying that marker. fake_stdin also
# holds the orchestrator's own records (task specs and results), which no assertion about one
# comment's text may read.
posted_of() { jq -r --arg m "<!-- factory:{\"kind\":\"$1\"" 'select(.body | split("\n") | last | startswith($m)) | .body' "$GH_SIM/comments.jsonl" | tr -d '\r'; }
# result_of <title>: the result the newest task with that title was completed or failed with.
result_of() { t3_q '[.tasks[] | select(.title == $t)] | last | .result // ""' --arg t "$1"; }
# status_line <task id> <status>: the line in the posted bodies where sf-act set that status.
status_line() { grep -n -F "\"kind\":\"status\",\"task\":\"$1\",\"status\":\"$2\"" "$FAKE_LOG.stdin" | head -n 1 | cut -d: -f1; }
# comment_fails <marker kind> [message]: gh fails to post a comment carrying that factory marker;
# comment_fails_after lets <n> of them through first. comment_ok undoes either.
comment_fails() { printf '%s\n' "${2:-gh: HTTP 502}" > "$GH_SIM/fail/$1"; }
comment_fails_after() { comment_fails "$1" "${3:-}"; echo "$2" > "$GH_SIM/fail/$1.after"; }
comment_ok() { rm -f "$GH_SIM/fail/$1" "$GH_SIM/fail/$1.after"; }
# requests_of <kind>: the request lines of that kind the foreman got.
requests_of() { jq -c --arg k "$1" 'select(has($k))' "$REQUESTS" 2> /dev/null | tr -d '\r'; }
# to_build: fires until build is dispatched (intake went go, no plan).
to_build() {
  acts
  finish intake "$GO"
  acts
  assert_eq dispatched "$(status_of build)" "build"
}
# to_review: then the gate passes and PR 12 opens; review is dispatched.
to_review() {
  to_build
  echo "PASS: pushed app-7" | fixture gantry-gate-evidence --force-with-lease
  open_pr_seq app-7 '' 12
  fixture gh pr create -R "$REPO" --draft --head app-7 --base main --title "Greet people" --body-file - < /dev/null
  finish build "$BUILT"
  acts
  assert_eq dispatched "$(status_of review)" "review"
}
# open_pr_seq <branch> <first> <then>: the first lookup prints <first>, later ones <then>.
open_pr_seq() {
  printf '%s\n' "$2" | fixture_seq 1 gh pr list -R "$REPO" --head "$1" --state open --json number -q '.[0].number // empty'
  printf '%s\n' "$3" | fixture_seq 2 gh pr list -R "$REPO" --head "$1" --state open --json number -q '.[0].number // empty'
}


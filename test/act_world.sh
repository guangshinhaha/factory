# shellcheck shell=sh
# shellcheck disable=SC2016,SC2034 # jq programs in single quotes; constants used by the test files
# A world for multi-fire tests of sf-act and sf-tick: real sf-state and sf-brief against a stateful
# fake orca (test/fakes/orca-sim) and fake gh; sf-ship, sf-stop and sf-hold are stubs that log
# their arguments. The checkout is a real git clone of a local bare origin.
# Repo acme/app, issue 7, branch app-7, PR 12. Sourced by test/sf_act_test.sh and sf_tick_test.sh.

REPO=acme/app
READY_EVENT='{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"}'
GO='factory-result: {"station":"intake","status":"go","tier":"low","work_type":"feature","plan_first":false}'
PLAN_FIRST='factory-result: {"station":"intake","status":"go","tier":"high","work_type":"feature","plan_first":true}'
BUILT='factory-result: {"station":"build","status":"built","head_sha":"abc","commits":1,"checks":"ok"}'
CLEAN='factory-result: {"station":"review","status":"clean","head_sha":"abc","comment_url":"u"}'
VERIFIED='factory-result: {"station":"verify","status":"PASS","verdict":"PASS","head_sha":"abc","comment_url":"u"}'
# Pending tasks whose deps are all completed turn ready (as orca-sim does).
PROMOTE='def promote: .tasks as $all | .tasks |= map(if .status == "pending" and all(.deps[]; . as $d | any($all[]; .id == $d and .status == "completed")) then .status = "ready" else . end);'

git_q() { git -c init.defaultBranch=main "$@" > /dev/null 2>&1; }

# stub <name>: a logging stand-in for a sibling sf-* script. Prints $TEST_TMP/<name>.out and
# exits with $TEST_TMP/<name>.exit (default 0).
stub() {
  cat > "$TEST_TMP/bin/$1" <<STUB
#!/bin/sh
printf '%s\n' "$1 \$*" >> "\$FAKE_LOG"
if [ -f "\$TEST_TMP/$1.out" ]; then cat "\$TEST_TMP/$1.out"; fi
exit "\$(cat "\$TEST_TMP/$1.exit" 2> /dev/null || echo 0)"
STUB
  chmod +x "$TEST_TMP/bin/$1"
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
  ORCA_SIM=$TEST_TMP/orca
  SHINSTACK_ROOT=$TEST_TMP/shinstack
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  FACTORY_ACT_LOG=$TEST_TMP/act.log
  export FACTORY_ACT_LOG FAKE_FIXTURES ORCA_SIM SHINSTACK_ROOT GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  mkdir -p "$FAKE_FIXTURES" "$ORCA_SIM/fail" "$ORCA_SIM/terminal" "$TEST_TMP/bin" "$SHINSTACK_ROOT/playbooks"
  for p in feature bug-fix refactoring opening-a-pr ship plan; do echo "# $p" > "$SHINSTACK_ROOT/playbooks/$p.md"; done
  printf '#!/bin/sh\nexec sh "%s/test/fakes/orca-sim" "$@"\n' "$FACTORY_ROOT" > "$TEST_TMP/bin/orca"
  chmod +x "$TEST_TMP/bin/orca"
  stub sf-ship
  stub sf-stop
  stub sf-hold
  PATH=$TEST_TMP/bin:$PATH
  export PATH

  if [ -d "${ACT_WORLD_TEMPLATE:-}/app" ]; then
    # test/run built the repos once; a copy plus one set-url is cheaper than seven git runs.
    cp -R "$ACT_WORLD_TEMPLATE/origin.git" "$ACT_WORLD_TEMPLATE/app" "$TEST_TMP/"
    git -C "$TEST_TMP/app" remote set-url origin "$TEST_TMP/origin.git"
    cd "$TEST_TMP/app" || fail "checkout not entered"
  else
    act_world_repos "$TEST_TMP"
  fi

  issues '[{"number":7,"labels":[{"name":"ready"}],"body":"Done when: it greets"}]'
  prs '[]'
  timeline "[$READY_EVENT]"
  echo https://github.com/acme/app/issues/7#c | fixture gh issue comment 7 -R "$REPO" --body-file -
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

# act: one sf-act fire; stdout/stderr in $TEST_TMP/out and err, exit status in $act_status.
act() {
  act_status=0
  sh "$FACTORY_ROOT/bin/sf-act" --repo "$REPO" > "$TEST_TMP/out" 2> "$TEST_TMP/err" || act_status=$?
}
acts() { act; assert_eq 0 "$act_status" "sf-act exit status (stderr: $(cat "$TEST_TMP/err"))"; }

sim() { jq -r "$@" "$ORCA_SIM/state.json"; }
sim_set() {
  f=$1
  shift
  jq "$@" "$PROMOTE$f | promote" "$ORCA_SIM/state.json" > "$ORCA_SIM/new" && mv "$ORCA_SIM/new" "$ORCA_SIM/state.json"
}
# status_of <title>: the status of the newest task with that title.
status_of() { sim --arg t "$1" '[.tasks[] | select(.title == $t)] | last | .status // "none"'; }
id_of() { sim --arg t "$1" '[.tasks[] | select(.title == $t)] | last | .id // ""'; }
spec_of() { sim --arg t "$1" '[.tasks[] | select(.title == $t)] | last | .spec // ""'; }
count_titled() { sim --arg t "$1" '[.tasks[] | select(.title == $t)] | length'; }
runs_count() { sim '.runs | length'; }
# finish <title> <body> [outcome]: the dispatched worker reports; failed unless succeeded.
finish() {
  sim_set '.tasks |= map(if .title == $t and .status == "dispatched"
      then .status = (if $o == "succeeded" then "completed" else "failed" end) | .result = ({provenance: "worker", outcome: $o, body: $b} | tojson)
      else . end)' --arg t "$1" --arg b "$2" --arg o "${3:-succeeded}"
}
dispatch_of() { sim --arg t "$(id_of "$1")" '[.dispatches[] | select(.task == $t)] | last | .id // ""'; }
agent_of() { sim --arg t "$(id_of "$1")" '[.dispatches[] | select(.task == $t)] | last | "\(.agent)/\(.model)"'; }
worktree_of() { sim --arg t "$(id_of "$1")" '[.dispatches[] | select(.task == $t)] | last | .worktree'; }
# escalation <title> <at>: Orca's "stopped without reporting" for the title's last dispatch.
escalation() {
  d=$(dispatch_of "$1")
  t=$(id_of "$1")
  r=$(sim --arg t "$t" '.tasks[] | select(.id == $t) | .run')
  sim_set '.inbox[$r] = ((.inbox[$r] // []) + [{type: "escalation", subject: "Worker stopped without reporting", payload: ({taskId: $t, dispatchId: $d} | tojson), created_at: $at}])' \
    --arg r "$r" --arg t "$t" --arg d "$d" --arg at "$2"
}
orca_fails() { printf '%s\n' "${2:-orca: boom}" > "$ORCA_SIM/fail/$1"; }
orca_fails_after() { orca_fails "$1" "${3:-orca: boom}"; echo "$2" > "$ORCA_SIM/fail/$1.after"; }
orca_ok() { rm -f "$ORCA_SIM/fail/$1" "$ORCA_SIM/fail/$1.after"; }

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


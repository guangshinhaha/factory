# shellcheck shell=sh
# sf-init: labels, risky paths + CLAUDE.md keys via a PR, Orca automation; a rerun writes nothing.
# Repo acme/app. git is real: origin is git@github.com:acme/app.git, which a fake ssh serves from
# bare repos under $TEST_TMP/remote. gh and orca are fakes.

REPO=acme/app
LABELS_Q='.[].name'
PR_URL=https://github.com/acme/app/pull/9
TITLE='chore: set up the factory (sf-init)'

# Identity by env, never git config.
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# world: origin with CLAUDE.md declaring shinstack-mode, a clone at $WS, a fresh repo on GitHub.
world() {
  FAKE_FIXTURES=$TEST_TMP/fx
  export FAKE_FIXTURES
  # What sf-init gives Orca as the precheck: this PATH, and sf-tick by its absolute path.
  PRECHECK="PATH='$PATH' sh '$FACTORY_ROOT/bin/sf-tick'"
  ORIGIN=$TEST_TMP/remote/acme/app.git
  WS=$TEST_TMP/ws
  mkdir -p "$TEST_TMP/remote/acme" "$TEST_TMP/seed"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$TEST_TMP/seed"
  printf '# app\n\n## shinstack\nshinstack-mode: auto\n\n## Other\nkeep me\n' > "$TEST_TMP/seed/CLAUDE.md"
  seed_commit
  # Fake ssh: run the remote git command (git-upload-pack 'acme/app.git') in $TEST_TMP/remote.
  cat > "$TEST_TMP/ssh" <<SSH
#!/bin/sh
for a; do cmd=\$a; done
cd '$TEST_TMP/remote' || exit 1
eval "\$(printf '%s\\n' "\$cmd" | sed "s|^git-\\([a-z-]*\\) '/*|git \\1 '|")"
SSH
  chmod +x "$TEST_TMP/ssh"
  GIT_SSH=$TEST_TMP/ssh
  export GIT_SSH
  git clone -q git@github.com:acme/app.git "$WS"
  WS=$(git -C "$WS" rev-parse --show-toplevel) # as sf-init sees it (C:/... on Windows)

  labels ""
  for l in ready needs-shin icebox risk:high; do label_create "$l" < /dev/null; done
  echo main | fixture gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name
  open_pr '[]'
  echo "$PR_URL" | fixture gh pr create -R "$REPO" --base main --head factory-init --title "$TITLE" --body-file -
  automations '[]'
  echo '{"ok":true}' | fixture orca automations create --name factory-acme/app --trigger '*/5 * * * *' --provider claude \
    --prompt /factory:foreman --precheck "$PRECHECK" --workspace "path:$WS" --json
}
seed_commit() {
  git -C "$TEST_TMP/seed" add -A
  git -C "$TEST_TMP/seed" commit -q -m seed
  git -C "$TEST_TMP/seed" push -q "$ORIGIN" HEAD:refs/heads/main
}
labels() { printf '%s\n' "$1" | fixture gh label list -R "$REPO" --limit 1000 --json name -q "$LABELS_Q"; }
label_create() {
  case "$1" in
    ready) d='The factory may build this' c=0e8a16 ;;
    needs-shin) d='Stopped by the factory; waits on a human' c=d93f0b ;;
    icebox) d='Parked; not for the factory' c=c5def5 ;;
    risk:high) d='Needs a human review even when CI is green' c=b60205 ;;
  esac
  fixture gh label create "$1" -R "$REPO" --color "$c" --description "$d"
}
open_pr() { printf '%s\n' "$1" | fixture gh pr list -R "$REPO" --head factory-init --state open --json url,isCrossRepository; }
automations() { printf '{"ok":true,"result":{"automations":%s,"items":[]}}\n' "$1" | fixture orca automations list --json; }
sf_init() { sh "$FACTORY_ROOT/bin/sf-init" --repo "$REPO" --workspace "$WS" "$@"; }
remote_file() { git -C "$ORIGIN" show "$1:$2"; }
writes() { grep -E '^(gh label create|gh pr create|orca automations create)' "$FAKE_LOG" || :; }

test_first_run_creates_everything() {
  world
  main_before=$(git -C "$ORIGIN" rev-parse main)
  sf_init > "$TEST_TMP/out"
  for l in ready needs-shin icebox risk:high; do assert_eq 1 "$(count_calls "gh label create $l ")" "creates of $l"; done
  assert_eq 1 "$(count_calls "gh pr create")" "PRs"
  assert_contains "$(fake_stdin)" "gantry-risky-paths"
  assert_eq 1 "$(count_calls "orca automations create")" "automations"
  assert_eq "$main_before" "$(git -C "$ORIGIN" rev-parse main)" "origin main"
  assert_eq "lefthook.yml
.github/workflows/**" "$(remote_file factory-init .github/gantry-risky-paths)" "risky paths"
  assert_eq "# app

## shinstack
shinstack-mode: auto
factory-concurrency: 2
factory-sensitive: false

## Other
keep me" "$(remote_file factory-init CLAUDE.md)" "CLAUDE.md"
  assert_eq "$main_before" "$(git -C "$ORIGIN" rev-parse factory-init~1)" "factory-init parent"
  assert_eq 1 "$(git -C "$WS" worktree list --porcelain | grep -c '^worktree')" "worktrees left in the workspace"
  assert_contains "$(cat "$TEST_TMP/out")" "sf-init: acme/app set up"
}

test_second_run_writes_nothing() {
  world
  sf_init > /dev/null
  # GitHub and Orca now have it all; the PR is still open.
  labels "ready
needs-shin
icebox
risk:high"
  open_pr '[{"url":"'"$PR_URL"'","isCrossRepository":false}]'
  automations '[{"id":"a1","name":"factory-acme/app"}]'
  branch_before=$(git -C "$ORIGIN" rev-parse factory-init)
  : > "$FAKE_LOG"
  sf_init > "$TEST_TMP/out"
  assert_eq "" "$(writes)" "gh/orca writes on the second run"
  assert_eq "$branch_before" "$(git -C "$ORIGIN" rev-parse factory-init)" "factory-init"
  assert_contains "$(cat "$TEST_TMP/out")" "file changes wait on $PR_URL"
}

test_run_after_the_pr_merged_writes_nothing() {
  world
  labels "ready
needs-shin
icebox
risk:high"
  automations '[{"id":"a1","name":"factory-acme/app"}]'
  mkdir -p "$TEST_TMP/seed/.github"
  printf '# mine\nskills/**\nlefthook.yml  # checks\n.github/workflows/**\n' > "$TEST_TMP/seed/.github/gantry-risky-paths"
  printf 'shinstack-mode: auto\nfactory-concurrency: 2\nfactory-sensitive: false\n' > "$TEST_TMP/seed/CLAUDE.md"
  seed_commit
  sf_init > "$TEST_TMP/out"
  assert_eq "" "$(writes)" "gh/orca writes"
  assert_eq 0 "$(count_calls "gh pr list")" "PR lookups"
  assert_contains "$(cat "$TEST_TMP/out")" "already set up on main"
}

test_partial_setup_is_completed_and_values_kept() {
  world
  labels "Ready
bug
icebox"
  automations '[{"id":"a1","name":"factory-other"}]'
  mkdir -p "$TEST_TMP/seed/.github"
  printf 'skills/**\nlefthook.yml' > "$TEST_TMP/seed/.github/gantry-risky-paths"
  printf 'shinstack-mode: supervised\nshinstack-mode.merge: ask\nfactory-concurrency: 4\n' > "$TEST_TMP/seed/CLAUDE.md"
  seed_commit
  sf_init > /dev/null
  assert_eq "needs-shin risk:high" "$(sed -n 's/^gh label create \([^ ]*\) .*/\1/p' "$FAKE_LOG" | tr '\n' ' ' | sed 's/ $//')" "labels created"
  assert_eq "skills/**
lefthook.yml
.github/workflows/**" "$(remote_file factory-init .github/gantry-risky-paths)" "risky paths"
  assert_eq "shinstack-mode: supervised
shinstack-mode.merge: ask
factory-sensitive: false
factory-concurrency: 4" "$(remote_file factory-init CLAUDE.md)" "CLAUDE.md"
  assert_eq 1 "$(count_calls "orca automations create --name factory-acme/app ")" "automation creates"
}

test_claude_md_without_shinstack_mode_gets_the_keys_appended() {
  world
  rm "$TEST_TMP/seed/CLAUDE.md"
  echo x > "$TEST_TMP/seed/README"
  seed_commit
  sf_init > /dev/null
  assert_eq "factory-concurrency: 2
factory-sensitive: false" "$(remote_file factory-init CLAUDE.md)" "new CLAUDE.md"
}

test_stale_branch_from_a_closed_pr_is_replaced() {
  world
  git -C "$TEST_TMP/seed" push -q "$ORIGIN" HEAD:refs/heads/factory-init
  echo stale > "$TEST_TMP/seed/stale"
  git -C "$TEST_TMP/seed" add stale
  git -C "$TEST_TMP/seed" commit -q -m stale
  git -C "$TEST_TMP/seed" push -q "$ORIGIN" HEAD:refs/heads/factory-init
  sf_init > /dev/null
  assert_eq "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$ORIGIN" rev-parse factory-init~1)" "factory-init parent"
  assert_eq 1 "$(count_calls "gh pr create")" "PRs"
}

test_pushed_without_a_pr_reruns_to_a_pr() {
  world
  fixture gh pr create -R "$REPO" --base main --head factory-init --title "$TITLE" --body-file - < /dev/null
  fixture_exit 1 "HTTP 502"
  status=0
  sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit with gh pr create failing"
  assert_contains "$(cat "$TEST_TMP/err")" "factory-init pushed but no PR open"
  assert_eq 0 "$(count_calls "orca automations create")" "automations after the failure"
  echo "$PR_URL" | fixture gh pr create -R "$REPO" --base main --head factory-init --title "$TITLE" --body-file -
  sf_init > /dev/null
  assert_eq 2 "$(count_calls "gh pr create")" "PR creates"
  assert_eq 1 "$(count_calls "orca automations create")" "automations"
}

test_label_create_failure_exits_1() {
  world
  label_create icebox < /dev/null
  fixture_exit 1 "HTTP 403"
  status=0
  sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "label icebox missing from acme/app"
  assert_eq 0 "$(count_calls "gh pr create")" "PRs"
}

test_unreadable_automation_list_creates_nothing() {
  world
  echo '{"ok":false,"error":"boom"}' | fixture orca automations list --json
  status=0
  sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "Orca automations list unreadable"
  assert_eq 0 "$(count_calls "orca automations create")" "automation creates"
}

test_workspace_of_another_repo_exits_2_without_writes() {
  world
  status=0
  sh "$FACTORY_ROOT/bin/sf-init" --repo acme/other --workspace "$WS" > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 2 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "not github.com/acme/other"
  assert_eq 0 "$(count_calls "gh ")" "gh calls"
}

test_default_workspace_is_the_main_checkout() {
  world
  git -C "$WS" worktree add -q --detach "$TEST_TMP/side"
  main=$WS # the side worktree's main checkout, in git's form
  echo '{"ok":true}' | fixture orca automations create --name factory-acme/app --trigger '*/5 * * * *' --provider claude \
    --prompt /factory:foreman --precheck "$PRECHECK" --workspace "path:$main" --json
  (cd "$TEST_TMP/side" && sh "$FACTORY_ROOT/bin/sf-init" --repo "$REPO") > /dev/null
  assert_called "orca automations create --name factory-acme/app --trigger */5 * * * * --provider claude --prompt /factory:foreman --precheck $PRECHECK --workspace path:$main --json"
}

test_bad_arguments_exit_2() {
  world
  status=0
  sf_init --bogus > /dev/null 2>&1 || status=$?
  assert_eq 2 "$status" "exit status"
  assert_eq 0 "$(count_calls "gh ")" "gh calls"
}

# sf-state and sf-ship read indented keys, so an indented key is present.
test_indented_key_keeps_its_value() {
  world
  printf 'shinstack-mode: auto\n\n## Factory\n  factory-concurrency: 4\n' > "$TEST_TMP/seed/CLAUDE.md"
  seed_commit
  sf_init > /dev/null
  assert_eq "shinstack-mode: auto
factory-sensitive: false

## Factory
  factory-concurrency: 4" "$(remote_file factory-init CLAUDE.md)" "CLAUDE.md"
}

test_origin_url_case_is_ignored() {
  world
  git -C "$WS" remote set-url origin ssh://git@GitHub.com/Acme/App.git
  mv "$TEST_TMP/remote/acme" "$TEST_TMP/remote/Acme"
  mv "$TEST_TMP/remote/Acme/app.git" "$TEST_TMP/remote/Acme/App.git"
  ORIGIN=$TEST_TMP/remote/Acme/App.git
  sf_init > /dev/null
  assert_eq 1 "$(count_calls "gh pr create")" "PRs"
}

test_push_url_of_another_repo_exits_2_without_writes() {
  world
  git init -q --bare "$TEST_TMP/remote/acme/evil.git"
  git -C "$WS" remote set-url --push origin git@github.com:acme/evil.git
  status=0
  sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 2 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "origin push URL is"
  assert_eq "" "$(git -C "$TEST_TMP/remote/acme/evil.git" for-each-ref)" "refs in the other repo"
  assert_eq 0 "$(count_calls "gh ")" "gh calls"
}

# git pushes to every push URL, not only the first.
test_second_push_url_of_another_host_exits_2_without_writes() {
  world
  git -C "$WS" remote set-url --push origin git@github.com:acme/app.git
  git -C "$WS" remote set-url --add --push origin https://evil.example/acme/app.git
  status=0
  sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 2 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "origin push URL is [https://evil.example/acme/app.git], not github.com/acme/app"
  assert_eq 0 "$(count_calls "gh ")" "gh calls"
}

# The name carries the owner, so other/app's automation is not acme/app's.
test_automation_of_a_same_named_repo_does_not_count() {
  world
  automations '[{"id":"a1","name":"factory-other/app"}]'
  sf_init > /dev/null
  assert_eq 1 "$(count_calls "orca automations create --name factory-acme/app ")" "automation creates"
}

test_symlinked_claude_md_exits_1_naming_it() {
  world
  git -C "$TEST_TMP/seed" mv CLAUDE.md AGENTS.md
  # A symlink built in the index: Git Bash's ln -s copies the file instead.
  link=$(printf 'AGENTS.md' | git -C "$TEST_TMP/seed" hash-object -w --stdin)
  git -C "$TEST_TMP/seed" update-index --add --cacheinfo "120000,$link,CLAUDE.md"
  git -C "$TEST_TMP/seed" commit -q -m link
  git -C "$TEST_TMP/seed" push -q "$ORIGIN" HEAD:refs/heads/main
  status=0
  sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "CLAUDE.md on main is a symlink"
  assert_eq 0 "$(count_calls "gh pr create")" "PRs"
}

# The target repo's hooks need its deps, which the temporary worktree lacks; CI on the PR is the gate.
test_target_repo_hooks_do_not_block_setup() {
  world
  hooks=$WS/.git/hooks
  mkdir -p "$hooks"
  # Each hook records that it ran: git ignores post-index-change's exit status.
  for h in post-checkout pre-commit commit-msg pre-push reference-transaction post-index-change; do
    printf '#!/bin/sh\necho %s >> "%s"\necho "%s: node_modules missing" >&2\nexit 1\n' "$h" "$TEST_TMP/hooks-ran" "$h" > "$hooks/$h"
    chmod +x "$hooks/$h"
  done
  git -C "$WS" config core.fsmonitor "$hooks/post-checkout" # a hook in all but name
  git -C "$TEST_TMP/seed" commit -q --allow-empty -m ahead # the workspace's fetch updates a ref
  git -C "$TEST_TMP/seed" push -q "$ORIGIN" HEAD:refs/heads/main
  status=0
  sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 0 "$status" "exit status ($(cat "$TEST_TMP/err"))"
  assert_eq "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$ORIGIN" rev-parse factory-init~1)" "factory-init parent"
  assert_eq 1 "$(count_calls "gh pr create")" "PRs"
  assert_eq "" "$(cat "$TEST_TMP/hooks-ran" 2> /dev/null)" "hooks run"
  for h in post-checkout pre-commit commit-msg pre-push reference-transaction post-index-change; do
    [ -x "$hooks/$h" ] || fail "hook $h removed from the workspace"
  done
}

# An outsider's fork can open a PR from a branch named factory-init too.
test_fork_pr_from_factory_init_is_not_the_setup_pr() {
  world
  open_pr '[{"url":"https://github.com/acme/app/pull/5","isCrossRepository":true}]'
  sf_init > "$TEST_TMP/out"
  assert_eq 1 "$(count_calls "gh pr create")" "PRs"
  case "$(cat "$TEST_TMP/out")" in *pull/5*) fail "output names the fork PR: $(cat "$TEST_TMP/out")" ;; esac
}

test_unreadable_pr_list_exits_1_without_a_push() {
  world
  for out in '[{"url":"x"}]' ''; do
    printf '%s' "$out" | fixture gh pr list -R "$REPO" --head factory-init --state open --json url,isCrossRepository
    status=0
    sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
    assert_eq 1 "$status" "exit status for [$out]"
    assert_contains "$(cat "$TEST_TMP/err")" "open PRs from factory-init not read"
  done
  assert_eq "" "$(git -C "$ORIGIN" for-each-ref refs/heads/factory-init)" "factory-init on origin"
}

test_origin_off_github_exits_2_without_writes() {
  world
  for url in https://gitlab.com/acme/app.git git@gitlab.com:acme/app.git \
    https://evil.example/x@github.com/acme/app.git https://github.com.evil.example/acme/app.git \
    ssh://git@github.com.evil.example/acme/app.git 'https://evil.example?@github.com/acme/app.git' \
    'https://evil.example#@github.com/acme/app.git' file://github.com/acme/app.git; do
    git -C "$WS" remote set-url origin "$url"
    status=0
    sf_init > /dev/null 2> "$TEST_TMP/err" || status=$?
    assert_eq 2 "$status" "exit status for $url"
    assert_contains "$(cat "$TEST_TMP/err")" "origin URL is [$url], not github.com/acme/app"
  done
  assert_eq 0 "$(count_calls "gh ")" "gh calls"
}

test_missing_gantry_gates_exit_1_naming_the_command_before_any_write() {
  world
  mkdir "$TEST_TMP/nogantry"
  for t in sh jq git dirname cat; do ln -s "$(command -v "$t")" "$TEST_TMP/nogantry/$t"; done
  # PATH without the dirs holding a gantry gate (see sf_act_test.sh).
  p=$TEST_TMP/nogantry
  for d in $(printf '%s\n' "$PATH" | tr ':' ' '); do
    [ -e "$d/gantry-gate-evidence" ] || [ -e "$d/gantry-verdict-check" ] || p=$p:$d
  done
  status=0
  PATH=$p "$TEST_TMP/nogantry/sh" "$FACTORY_ROOT/bin/sf-init" --repo "$REPO" --workspace "$WS" > /dev/null 2> "$TEST_TMP/err" || status=$?
  assert_eq 1 "$status" "sf-init exit status"
  assert_contains "$(cat "$TEST_TMP/err")" "gantry-gate-evidence not found on PATH"
  assert_eq "" "$(writes)" "writes"
  assert_eq 0 "$(count_calls "gh ")" "gh calls"
}

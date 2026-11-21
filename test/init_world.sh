# shellcheck shell=sh
# The git half of the world in test/sf_init_test.sh: under <dir>, remote/acme/app.git (bare origin
# with the seed commit on main), seed (the working repo that feeds it) and ws (a clone of origin).
# test/run builds one in $INIT_WORLD_TEMPLATE; world() copies it, or builds its own with no template.
# The clone's URL is git@github.com:acme/app.git, so a copy needs no fixing up.

# Identity by env, never git config.
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# seed_commit: commit the seed repo's changes and push them to origin's main.
seed_commit() {
  git -C "$TEST_TMP/seed" add -A
  git -C "$TEST_TMP/seed" commit -q -m seed
  git -C "$TEST_TMP/seed" push -q "$ORIGIN" HEAD:refs/heads/main
}

# init_world_ssh <dir>: <dir>/ssh, a fake ssh that runs the remote git command (git-upload-pack
# 'acme/app.git') in <dir>/remote.
init_world_ssh() {
  cat > "$1/ssh" <<SSH
#!/bin/sh
for a; do cmd=\$a; done
cd '$1/remote' || exit 1
eval "\$(printf '%s\\n' "\$cmd" | sed "s|^git-\\([a-z-]*\\) '/*|git \\1 '|")"
SSH
  chmod +x "$1/ssh"
}

# init_world_repos <dir>: build remote, seed and ws under <dir>.
init_world_repos() {
  TEST_TMP=$1
  ORIGIN=$1/remote/acme/app.git
  mkdir -p "$1/remote/acme" "$1/seed"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$1/seed"
  printf '# app\n\n## shinstack\nshinstack-mode: auto\n\n## Other\nkeep me\n' > "$1/seed/CLAUDE.md"
  seed_commit
  init_world_ssh "$1"
  GIT_SSH=$1/ssh git clone -q git@github.com:acme/app.git "$1/ws"
}

# init_world_copy <dir>: remote, seed and ws in <dir>.
init_world_copy() {
  if [ -d "${INIT_WORLD_TEMPLATE:-}/ws" ]; then
    cp -R "$INIT_WORLD_TEMPLATE/remote" "$INIT_WORLD_TEMPLATE/seed" "$INIT_WORLD_TEMPLATE/ws" "$1/"
  else
    init_world_repos "$1"
  fi
}

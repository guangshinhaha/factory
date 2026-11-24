# shellcheck shell=sh
# The git half of the world in test/sf_ship_test.sh: <dir>/origin.git (bare) and <dir>/app, a clone
# on app-7, one commit ahead of main and pushed. test/run builds one per mode in
# $SHIP_WORLD_TEMPLATE-<mode>; world() copies it, and builds its own for a mode with no template.

git_q() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@" > /dev/null 2>&1; }

# commit <file> <text>: write and commit a file in the current checkout.
commit() {
  printf '%s\n' "$2" > "$1"
  git add "$1" && git_q commit -m "change $1"
}

# ship_world_repos <mode> <dir>: build the repos; cd into app.
ship_world_repos() {
  git_q init --bare "$2/origin.git"
  git -C "$2/origin.git" symbolic-ref HEAD refs/heads/main
  git_q clone "$2/origin.git" "$2/app"
  cd "$2/app" || fail "checkout not entered"
  git config user.email test@example.com
  git config user.name test
  git_q checkout -b main
  printf '# app\n\nshinstack-mode: %s\n' "$1" > CLAUDE.md
  git add CLAUDE.md && git_q commit -m init
  commit shared.txt base
  git_q push origin main
  git_q checkout -b app-7
  commit feature.txt feature
  git_q push -u origin app-7
}

# ship_world_copy <mode> <dir>: the repos in <dir>, from the template when there is one.
ship_world_copy() {
  if [ -d "${SHIP_WORLD_TEMPLATE:-}-$1/app" ]; then
    cp -R "$SHIP_WORLD_TEMPLATE-$1/origin.git" "$SHIP_WORLD_TEMPLATE-$1/app" "$2/"
    repoint_origin "$2/app" "$2/origin.git"
  else
    ship_world_repos "$1" "$2"
  fi
}

# shellcheck shell=sh
# Shared helpers for the sf-* exit scripts (sf-stop, sf-hold, sf-ship). Sourced, never run.
# The caller sets `me` (its own name, for messages) before sourcing.
# shellcheck disable=SC2154 # me comes from the caller

die() {
  echo "$me: $*" >&2
  exit 1
}

usage_error() {
  echo "$me: $*" >&2
  exit 2
}

need_jq() {
  command -v jq > /dev/null 2>&1 || usage_error "jq not found on PATH"
}

# resolve_repo [owner/repo]: print owner/repo, from the argument or the current directory's repo.
resolve_repo() {
  r=${1:-}
  if [ -z "$r" ]; then
    r=$(gh repo view --json nameWithOwner -q .nameWithOwner) || usage_error "repo not found for the current directory (gh repo view failed)"
  fi
  case "$r" in
    */*) printf '%s\n' "$r" ;;
    *) usage_error "repo [$r] is not owner/repo" ;;
  esac
}

# act_log <owner/repo>: the path of the file where sf-act leaves why it last failed (one line,
# replaced by each failure, removed by a clean run). sf-tick reads it. FACTORY_ACT_LOG overrides.
act_log() {
  printf '%s\n' "${FACTORY_ACT_LOG:-/tmp/factory-act-$(id -u)-${1%%/*}-${1#*/}.log}"
}

is_number() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
}

# markers_since_ready <repo> <issue>: print a JSON array of the issue's factory marker objects
# (<!-- factory:{"kind":...} -->) from OWNER/MEMBER/COLLABORATOR comments made after the last
# `ready` label event, oldest first. sf-state reads markers the same way.
# Returns 1, printing nothing, when the timeline can't be read.
markers_since_ready() {
  tl=$(gh api "repos/$1/issues/$2/timeline" --paginate) || return 1
  printf '%s\n' "$tl" | jq -cs '
    if length > 0 and all(.[]; type == "array") then add else error("no JSON array") end
    | ([.[] | select(.event == "labeled" and .label.name == "ready") | .created_at] | max // "") as $since
    | [.[] | select(.event == "commented" and .created_at > $since
          and ((.author_association // "") as $a | ["OWNER", "MEMBER", "COLLABORATOR"] | index($a)))
        | (.body // "") | scan("<!-- factory:(\\{.*?\\}) -->") | .[0] | (try fromjson catch empty)]
  ' 2> /dev/null || return 1
}

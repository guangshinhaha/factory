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

# ask_body <owner/repo> <pr|""> <headline> <why a human> [action]: print the comment body for a
# human ask: the headline, why a human is needed, then four parts built only from GitHub data
# (PR files, risk label, station comments that name the head, head SHA), then one recommended
# action. Every gh read is best effort: a part whose data can't be read says so, it is never
# guessed. Used by sf-stop (every stop) and sf-ship (the merge ask). Never fails.
#
# The comment is public and posted under the owner's account, and the PR may come from a fork, so
# every string copied from GitHub is untrusted: file names and station lines are cut down to
# [A-Za-z0-9._/+=,:~ -] (anything else becomes ?), truncated, and shown in a code span; a fork PR
# shows a file count, no names. Whatever else is in the text, `<!--` never leaves this function, so
# markers_since_ready can never read a marker out of it. Callers append their own marker after it.
ask_body() {
  ask_body_text "$@" | sed 's/<!--/\&lt;!--/g'
}

# ask_body_text: ask_body before the `<!--` guard.
# shellcheck disable=SC2016 # backticks in the printed text are Markdown, not command substitution
ask_body_text() {
  ab_repo=$1 ab_pr=$2 ab_headline=$3 ab_why=$4 ab_action=${5:-}
  ab_files='' ab_nfiles='' ab_fork=unknown ab_labels='' ab_head='' ab_seen='' ab_other=''
  if [ -n "$ab_pr" ]; then
    ab_json=$(gh pr view "$ab_pr" -R "$ab_repo" --json files,labels,headRefOid 2> /dev/null) || ab_json=
    if [ -n "$ab_json" ]; then
      ab_head=$(printf '%s\n' "$ab_json" | jq -r '.headRefOid // empty' 2> /dev/null | tr -cd 'A-Za-z0-9')
      ab_labels=$(printf '%s\n' "$ab_json" | jq -r '[.labels[]?.name] | join(",")' 2> /dev/null | tr -cd 'A-Za-z0-9:_.,-')
      ab_nfiles=$(printf '%s\n' "$ab_json" | jq -r '[.files[]?.path] | length' 2> /dev/null)
      # Names are untrusted: sanitised and capped in jq so a newline in a name cannot split the output.
      ab_files=$(printf '%s\n' "$ab_json" | jq -r '[.files[]?.path
          | tostring | gsub("[^A-Za-z0-9._/+=,:~ -]"; "?") | gsub("(?i)factory:"; "factory_") | .[0:60] + (if length > 60 then "..." else "" end) | "`" + . + "`"]
        | if length == 0 then "" else (.[0:8] | join(", ")) + (if length > 8 then ", and \(length - 8) more" else "" end) end' 2> /dev/null)
      case $(gh pr view "$ab_pr" -R "$ab_repo" --json isCrossRepository 2> /dev/null | jq -r '.isCrossRepository' 2> /dev/null) in
        false) ab_fork=no ;;
        true) ab_fork=yes ;;
      esac
    fi
    ab_cm=$(gh api "repos/$ab_repo/issues/$ab_pr/comments" --paginate 2> /dev/null) || ab_cm=
    if [ -n "$ab_cm" ] && [ -n "$ab_head" ]; then
      # Trusted comments with a Findings: line are the stations' reports; those naming the head saw it.
      ab_all=$(printf '%s\n' "$ab_cm" | jq -rs --arg h "$ab_head" '
        if all(.[]; type == "array") then add else empty end
        | [.[] | select((.author_association // "") as $a | ["OWNER", "MEMBER", "COLLABORATOR"] | index($a))
            | select((.body // "") | test("(^|\n)Findings:") or contains("Codex review not run: "))]
        | {at: [.[] | select(.body | contains($h)) | (.body | split("\n") | map(select(test("^(factory |Findings:|Codex review not run)"))) | map(gsub("[^A-Za-z0-9._/+=,:~ -]"; "?") | gsub("(?i)factory:"; "factory_") | .[0:140]) | join(" / ") | "`" + . + "`")],
           n: length}
        | (.at[] | "S:" + .), (if (.at | length) == 0 and .n > 0 then "O:" else empty end)' 2> /dev/null) || ab_all=
      ab_seen=$(printf '%s\n' "$ab_all" | sed -n 's/^S://p')
      ab_other=$(printf '%s\n' "$ab_all" | sed -n '/^O:/p')
    fi
  fi

  printf '%s\n\n' "$ab_headline"
  printf '**Why a human is needed:** %s' "$ab_why"
  if [ -n "$ab_other" ]; then
    printf ' A fix landed after the last review, so no station has seen this head.'
  fi
  printf '\n\n'
  if [ -z "$ab_pr" ]; then
    printf '**What this changes:** unknown: there is no PR yet.\n'
  elif [ "$ab_fork" != no ] && [ -n "$ab_nfiles" ]; then
    if [ "$ab_fork" = yes ]; then ab_from='is from a fork'; else ab_from='is not confirmed to be from this repo'; fi
    printf '**What this changes:** PR #%s %s and changes %s files; read them with `gh pr diff %s -R %s`. Whether anything runs it yet is not known to the factory.\n' "$ab_pr" "$ab_from" "$ab_nfiles" "$ab_pr" "$ab_repo"
  elif [ -n "$ab_files" ]; then
    printf '**What this changes:** PR #%s touches: %s. Whether anything runs it yet is not known to the factory.\n' "$ab_pr" "$ab_files"
  else
    printf '**What this changes:** PR #%s files not read from GitHub.\n' "$ab_pr"
  fi
  case ",$ab_labels," in
    *,risk:high,*) printf '**Why it is risky:** labelled risk:high (skills, gate scripts or automation setup, per .github/gantry-risky-paths). The factory records the tier, not which line is risky: open the files above.\n' ;;
    *,risk:*) printf '**Why it is risky:** labelled %s. The factory records the tier, not which line is risky.\n' "$(printf '%s\n' "$ab_labels" | tr ',' '\n' | grep '^risk:' | head -n 1)" ;;
    *) printf '**Why it is risky:** unknown: no risk label read%s.\n' "${ab_pr:+ on PR #$ab_pr}" ;;
  esac
  if [ -z "$ab_head" ]; then
    printf '**Already checked:** unknown: no PR head SHA read.\n'
  elif [ -n "$ab_seen" ]; then
    printf '**Already checked** (head %s): %s\n' "$ab_head" "$(printf '%s\n' "$ab_seen" | paste -sd ';' - | sed 's/;/; /g')"
  else
    printf '**Already checked** (head %s): no station comment names this head.\n' "$ab_head"
  fi
  if [ -n "$ab_pr" ]; then
    printf '**Check it yourself:**\n'
    printf -- '- `gh pr diff %s -R %s`: the diff reads as the files above say.\n' "$ab_pr" "$ab_repo"
    printf -- '- `gh pr checks %s -R %s`: every check passes.\n' "$ab_pr" "$ab_repo"
    printf -- '- `gh pr view %s -R %s --json headRefOid -q .headRefOid`: prints the head above; a different SHA means the head moved.\n' "$ab_pr" "$ab_repo"
  else
    printf '**Check it yourself:** `gh issue view` the issue and the Run in Orca; there is no PR to diff yet.\n'
  fi
  if [ -z "$ab_action" ]; then
    if [ -n "$ab_other" ]; then
      ab_action="Label the issue ready again so review and verify rerun on this head, rather than merging unseen."
    else
      ab_action="Read the reason, fix or re-scope the issue, then label it ready again."
    fi
  fi
  printf '\n**Recommended:** %s\n' "$ab_action"
}

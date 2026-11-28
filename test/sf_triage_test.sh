# shellcheck shell=sh
# sf-triage: the untriaged and stale-ready lists, whether to send the owner a batch, and the
# markers that record it was sent. gh is faked; sf-state is stubbed (its summary file is the
# only thing sf-triage reads from it). The repo is acme/app.

REPO=acme/app

# world: no open issues, no merged PRs, no comments, two free slots and nothing to start.
world() {
  FAKE_FIXTURES=$TEST_TMP/fx
  export FAKE_FIXTURES
  mkdir -p "$FAKE_FIXTURES/gh" "$TEST_TMP/plugin/bin" "$TEST_TMP/plugin/lib"
  cp "$FACTORY_ROOT/bin/sf-triage" "$TEST_TMP/plugin/bin/"
  cp "$FACTORY_ROOT/lib/factory.sh" "$TEST_TMP/plugin/lib/"
  free 2 0
  open_issues '[]'
  merged '[]'
  comments '[]'
  cd "$TEST_TMP" || fail "test dir not entered: $TEST_TMP"
}

# free <free slots> <starts>: what the stubbed sf-state reports.
free() {
  cat > "$TEST_TMP/plugin/bin/sf-state" <<STUB
#!/bin/sh
echo "sf-state \$* requests=[\${FACTORY_T3_REQUESTS:-}]" >> "\$FAKE_LOG"
printf '{"free":%s,"starts":%s}\n' $1 $2 > "\$FACTORY_STATE_SUMMARY"
echo '[]'
STUB
  chmod +x "$TEST_TMP/plugin/bin/sf-state"
}

open_issues() { printf '%s\n' "$1" | fixture gh api "repos/$REPO/issues?state=open&per_page=100" --paginate; }
merged() { printf '%s\n' "$1" | fixture gh pr list -R "$REPO" --state merged --limit 200 --json number,headRefName,mergedAt,isCrossRepository; }
comments() { printf '%s\n' "$1" | fixture gh api "repos/$REPO/issues/comments?per_page=100" --paginate; }
timeline() { printf '%s\n' "$2" | fixture gh api "repos/$REPO/issues/$1/timeline" --paginate; }

# issue <n> [labels csv] [association]
issue() {
  il=$(jq -nc --arg l "${2:-}" '$l | split(",") | map({name: .})')
  printf '{"number":%s,"title":"issue %s","html_url":"https://github.com/%s/issues/%s","labels":%s,"author_association":"%s"}' \
    "$1" "$1" "$REPO" "$1" "$il" "${3:-OWNER}"
}
merged_pr() { printf '{"number":%s,"headRefName":"%s","mergedAt":"%s","isCrossRepository":%s}' "$1" "$2" "$3" "${4:-false}"; }
readied() { timeline "$1" "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"$2\"}]"; }
# sent <issue> <list> [association] [created_at]
sent() {
  printf '{"author_association":"%s","created_at":"%s","body":"factory: sent to you for triage.\\n\\n<!-- factory:{\\"kind\\":\\"triage-sent\\",\\"%s\\":[%s]} -->"}' \
    "${3:-OWNER}" "${4:-2026-11-20T00:00:00Z}" "$2" "$1"
}

triage() { sh "$TEST_TMP/plugin/bin/sf-triage" "$@"; }
# field <jq filter> <json>
field() { printf '%s' "$2" | jq -c "$1" | tr -d '\r'; }

no_writes() {
  assert_eq 0 "$(count_calls 'gh issue edit')" "issue edits"
  assert_eq 0 "$(count_calls 'gh issue comment')" "comments"
}

test_one_unlabelled_issue_with_an_empty_queue_is_sent_and_nothing_is_written() {
  world
  open_issues "[$(issue 7)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq true "$(field .send "$out")" send
  assert_eq '[7]' "$(field '[.untriaged[].number]' "$out")" untriaged
  assert_eq '{"untriaged":[7],"stale":[]}' "$(field .new "$out")" new
  no_writes
}

test_labelled_issues_and_pull_requests_are_not_untriaged() {
  world
  open_issues "[$(issue 1 needs-shin),$(issue 2 icebox),$(issue 3 epic),$(issue 4 ready),$(issue 5 bug,risk:high),{\"number\":6,\"title\":\"a PR\",\"html_url\":\"u\",\"labels\":[],\"author_association\":\"OWNER\",\"pull_request\":{}}]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq '[5]' "$(field '[.untriaged[].number]' "$out")" untriaged
}

test_pages_of_issues_are_joined() {
  world
  open_issues "[$(issue 1)]
[$(issue 2)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq '[1,2]' "$(field '[.untriaged[].number]' "$out")" untriaged
}

test_an_outsiders_issue_is_marked_untrusted() {
  world
  open_issues "[$(issue 1 '' MEMBER),$(issue 2 '' NONE),$(issue 3 '' CONTRIBUTOR)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq '[[1,true],[2,false],[3,false]]' "$(field '[.untriaged[] | [.number, .trusted]]' "$out")" trust
}

test_a_set_already_sent_is_not_sent_again() {
  world
  open_issues "[$(issue 7)]"
  comments "[$(sent 7 untriaged)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq false "$(field .send "$out")" send
  assert_eq 0 "$(count_calls 'sf-state')" "sf-state calls when nothing is new"
}

test_a_new_issue_sends_the_batch_again_with_every_row() {
  world
  open_issues "[$(issue 7),$(issue 9)]"
  comments "[$(sent 7 untriaged)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq true "$(field .send "$out")" send
  assert_eq '[7,9]' "$(field '[.untriaged[].number]' "$out")" untriaged
  assert_eq '[9]' "$(field .new.untriaged "$out")" new
}

test_an_outsiders_sent_marker_does_not_count() {
  world
  open_issues "[$(issue 7)]"
  comments "[$(sent 7 untriaged NONE)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq true "$(field .send "$out")" send
}

test_no_batch_while_the_factory_has_work_to_start() {
  world
  free 1 1
  open_issues "[$(issue 7)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq false "$(field .send "$out")" send
}

test_no_batch_without_a_free_slot() {
  world
  free 0 0
  open_issues "[$(issue 7)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq false "$(field .send "$out")" send
}

test_ready_issue_with_a_pr_merged_since_it_was_readied_is_stale() {
  world
  open_issues "[$(issue 7 ready)]"
  merged "[$(merged_pr 12 app-7 2026-11-10T00:00:00Z)]"
  readied 7 2026-11-01T00:00:00Z
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq true "$(field .send "$out")" send
  assert_eq '[[7,12]]' "$(field '[.stale[] | [.number, .pr]]' "$out")" stale
  assert_eq '[7]' "$(field .new.stale "$out")" new
  no_writes
}

test_a_pr_merged_before_the_issue_was_re_readied_is_not_stale() {
  world
  open_issues "[$(issue 7 ready)]"
  merged "[$(merged_pr 12 app-7-fix 2026-11-10T00:00:00Z)]"
  readied 7 2026-11-11T00:00:00Z
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq '[]' "$(field .stale "$out")" stale
}

test_fork_prs_and_other_issues_branches_are_not_stale() {
  world
  open_issues "[$(issue 7 ready)]"
  merged "[$(merged_pr 12 app-7 2026-11-10T00:00:00Z true),$(merged_pr 13 app-70 2026-11-10T00:00:00Z),$(merged_pr 14 debrief-app-7 2026-11-10T00:00:00Z)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq '[]' "$(field .stale "$out")" stale
}

test_a_stale_marker_from_before_the_last_ready_does_not_count() {
  world
  open_issues "[$(issue 7 ready)]"
  merged "[$(merged_pr 12 app-7 2026-11-25T00:00:00Z)]"
  readied 7 2026-11-22T00:00:00Z
  comments "[$(sent 7 stale OWNER 2026-11-20T00:00:00Z)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq true "$(field .send "$out")" send
  comments "[$(sent 7 stale OWNER 2026-11-26T00:00:00Z)]"
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq false "$(field .send "$out")" "send after a newer marker"
}

test_a_failed_read_prints_nothing() {
  world
  open_issues "[$(issue 7)]"
  fixture gh api "repos/$REPO/issues/comments?per_page=100" --paginate < /dev/null
  fixture_exit 1 "HTTP 502"
  rc=0
  out=$(triage "$REPO" 2> "$TEST_TMP/err") || rc=$?
  assert_eq 1 "$rc" status
  assert_eq '' "$out" stdout
}

test_output_that_is_not_a_list_is_a_failed_read() {
  world
  open_issues '{"message":"rate limited"}'
  rc=0
  out=$(triage "$REPO" 2> "$TEST_TMP/err") || rc=$?
  assert_eq 1 "$rc" status
  assert_eq '' "$out" stdout
}

test_a_failed_sf_state_sends_nothing() {
  world
  printf '#!/bin/sh\nexit 1\n' > "$TEST_TMP/plugin/bin/sf-state"
  open_issues "[$(issue 7)]"
  rc=0
  out=$(triage "$REPO" 2> "$TEST_TMP/err") || rc=$?
  assert_eq 1 "$rc" status
  assert_eq '' "$out" stdout
}

test_sent_records_the_whole_batch_in_one_comment() {
  world
  printf '' | fixture gh issue comment 7 -R "$REPO" --body-file -
  triage sent "$REPO" '{"untriaged":[7,8],"stale":[9]}' || fail "sent failed"
  assert_eq 1 "$(count_calls 'gh issue comment')" "comments"
  assert_called "gh issue comment 7 -R $REPO --body-file -"
  assert_contains "$(fake_stdin)" '<!-- factory:{"kind":"triage-sent","untriaged":[7,8],"stale":[9]} -->'
  assert_eq 0 "$(count_calls 'gh issue edit')" "issue edits"
}

test_sent_with_nothing_new_posts_nothing() {
  world
  triage sent "$REPO" '{"untriaged":[],"stale":[]}' || fail "sent failed"
  assert_eq 0 "$(count_calls 'gh issue comment')" "comments"
}

test_one_marker_naming_the_batch_silences_every_issue_in_it() {
  world
  open_issues "[$(issue 7),$(issue 9)]"
  comments '[{"author_association":"OWNER","created_at":"2026-11-20T00:00:00Z","body":"<!-- factory:{\"kind\":\"triage-sent\",\"untriaged\":[7,9],\"stale\":[]} -->"},{"author_association":"OWNER","created_at":"2026-11-20T00:00:00Z","body":"<!-- factory:7 -->"},{"author_association":"OWNER","created_at":"2026-11-20T00:00:00Z","body":"<!-- factory:{\"kind\":\"triage-sent\",\"untriaged\":\"x\"} -->"}]'
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq false "$(field .send "$out")" send
}

test_the_title_holds_for_the_same_new_set_and_changes_when_an_issue_goes_stale_again() {
  world
  open_issues "[$(issue 7 ready)]"
  merged "[$(merged_pr 12 app-7 2026-11-10T00:00:00Z)]"
  readied 7 2026-11-01T00:00:00Z
  first=$(field .title "$(triage "$REPO")")
  assert_contains "$first" "\"$REPO triage batch "
  assert_eq "$first" "$(field .title "$(triage "$REPO")")" "same set"
  merged "[$(merged_pr 15 app-7 2026-11-25T00:00:00Z)]"
  readied 7 2026-11-22T00:00:00Z
  [ "$first" != "$(field .title "$(triage "$REPO")")" ] || fail "title reused after a re-ready: $first"
}

test_a_pr_merged_before_a_reopen_is_not_stale() {
  world
  open_issues "[$(issue 7 ready)]"
  merged "[$(merged_pr 12 app-7 2026-11-10T00:00:00Z)]"
  timeline 7 '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-01T00:00:00Z"},{"event":"reopened","created_at":"2026-11-11T00:00:00Z"}]'
  out=$(triage "$REPO") || fail "sf-triage failed"
  assert_eq '[]' "$(field .stale "$out")" stale
}

test_sent_refuses_anything_but_issue_numbers() {
  world
  for bad in '' '{}' '{"untriaged":["7; rm"],"stale":[]}' '{"untriaged":[1.5],"stale":[]}' '{"untriaged":[],"stale":[],"x":1}'; do
    rc=0
    triage sent "$REPO" "$bad" 2> "$TEST_TMP/err" || rc=$?
    assert_eq 2 "$rc" "status for [$bad]"
  done
  assert_eq 0 "$(count_calls 'gh issue comment')" "comments"
}

test_a_failed_marker_exits_nonzero() {
  world
  fixture gh issue comment 7 -R "$REPO" --body-file - < /dev/null
  fixture_exit 1 "HTTP 502"
  rc=0
  triage sent "$REPO" '{"untriaged":[7],"stale":[]}' 2> "$TEST_TMP/err" || rc=$?
  assert_eq 1 "$rc" status
}

test_sf_state_is_asked_without_a_request_file() {
  world
  open_issues "[$(issue 7)]"
  FACTORY_T3_REQUESTS=$TEST_TMP/requests.jsonl triage "$REPO" > /dev/null || fail "sf-triage failed"
  assert_called "sf-state $REPO requests=[]"
}

test_list_never_asks_sf_state() {
  world
  open_issues "[$(issue 7)]"
  out=$(triage list "$REPO") || fail "sf-triage list failed"
  assert_eq false "$(field .send "$out")" send
  assert_eq '[7]' "$(field '[.untriaged[].number]' "$out")" untriaged
  assert_eq 0 "$(count_calls 'sf-state')" "sf-state calls"
  no_writes
}

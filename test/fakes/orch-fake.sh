# shellcheck shell=sh
# A fixture-replaying stand-in for lib/orch-t3.sh, for tests of sf-state: sf_state_test.sh runs a
# copy of the plugin with this file as its lib/orch-t3.sh. Each read sf-state makes is a fake-cli
# call `orch <verb> [run]` (fixtures in $FAKE_FIXTURES/orch). The real functions have their own
# tests in test/orch_t3_test.sh.
orch_fake() { sh "$FACTORY_ROOT/test/fakes/fake-cli" orch "$@"; }
orch_run_list() { orch_fake run-list; }
orch_task_list() { orch_fake task-list "$1"; }
orch_inbox() { orch_fake inbox "$1"; }
orch_worktree_ps() { orch_fake worktree-ps; }

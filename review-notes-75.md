### Claude

## Verdict
approve

## Real issues
None.

## Questions

- `test_drift_between_lists_is_flagged`'s second case claims to test "a different spelling for one app (the doc and rebar set point at different apps)". It doesn't. `Swapped` rewrites `soma_runtime` to `soma_event_store`, but `soma_event_store` is already in the rebar set, so after `usort` the doc set is just the rebar set minus `soma_runtime` — the same shape as the first "dropped one" case. The assertion still holds (drift is flagged), but the comment oversells what the second `assertNotEqual` proves. Cosmetic; the test does its job.
- The drift test exercises `doc_named_apps/1` plus the comparison against synthetic doc strings, not the real `test_doc_app_list_matches_rebar_release` against the real files. That's the right call — a test can't mutate the checked-in files — and the logic under test is identical. Flagging it so the choice is on record, not because it's wrong.

## Nits

- The doc smoke-test command is one long inline expression piped to `bin/soma console`. Same readability cost as the existing session smoke test it mirrors. Consistent, so leave it.
- Doc command reads status with `soma_actor:get_task_status/2` (returns a `#{task_id, correlation_id, status}` map), while the backing CT suite reads it through `sys:get_state` internals. The two confirm the same `completed` status by different means; the doc path is the human-facing API, which is the better choice for a copy-paste command.

## Functional evidence
- Criterion 1 — pass: `rebar.config` `{release, {soma, "0.1.0"}, [...]}` lists `soma_actor` between `soma_runtime` and `sasl` (diff hunk at rebar.config line 29). `test_actor_bundled_in_rebar_and_doc` asserts `lists:member(soma_actor, rebar_release_apps())`, green.
- Criterion 2 — pass: `docs/release.md` "Bundled apps" list gains `` - `soma_actor` `` after `soma_runtime`. `test_actor_bundled_in_rebar_and_doc` asserts `lists:member(soma_actor, doc_named_apps(read_doc()))`, green.
- Criterion 3 — pass: `grep -rn "not yet bundled" docs/` returns no hit in `docs/release.md` (only the test file's assertion literal and comment match). `test_doc_drops_not_yet_bundled` asserts the phrase absent, green.
- Criterion 4 — pass: `test_actor_bundled_in_rebar_and_doc` in `apps/soma_tools/test/soma_release_app_list_tests.erl` asserts `soma_actor` is a member of both the rebar release set and the doc bundled set. Module run: 6 tests, 0 failures.
- Criterion 5 — pass: `test_doc_app_list_matches_rebar_release` still compares the full rebar set against the full doc set with `?assertEqual`; `test_drift_between_lists_is_flagged` constructs a doc that drops `soma_actor` and a doc with a swapped app, asserting `?assertNotEqual` against the real rebar set in both directions. Green.
- Criterion 6 — pass: `docs/release.md` "Actor boot smoke test" section starts an actor with `soma_actor_sup:start_actor/1`, sends a one-step `echo` steps envelope, polls `soma_actor:get_task_status/2` to `completed`. `test_doc_has_actor_smoke_test` asserts the doc names `soma_actor_sup:start_actor`, `soma_actor:get_task_status`, `echo`, `completed`. Backing CT proof `actor_only_start_runs_steps_to_terminal` (`soma_actor_startup_SUITE`) runs the same boot→echo→completed path, green. The documented envelope shape matches the suite's `#{type, payload, task_id, steps}`.
- Criterion 7 — pass: `rebar3 eunit` → 119 tests, 0 failures; `rebar3 ct` → All 142 tests passed.

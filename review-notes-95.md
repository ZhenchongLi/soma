### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `init(#{log := Path})` matches `disk_log:open` returning `{ok, Log}` or `{repaired, Log, _, _}`. It has no clause for `{error, Reason}`. A path whose parent directory is missing, or one the BEAM can't write, makes `open` return `{error, _}` and `init/1` dies with a function_clause. No criterion covers this, and the persistent path is opt-in (tests only, default release stays in-memory via `start_link, []`), so it doesn't block. Flag for the operator-facing slice that wires a real path into a release. I verified open returns `{ok, Log}` for both the append-garbage and mid-term-truncation cases, so the corrupt-tail criterion is unaffected — the bad bytes surface at `disk_log:chunk`, which the replay loop handles.

## Nits
- `read_one_log_term/1` in the test handles `{repaired, Name, _, {badbytes, 0}}` but not nonzero badbytes. Fine for criterion 3 (it stops the store cleanly first, so badbytes is 0), but the clause head reads narrower than the comment above it suggests.
- `usage_doc_dir/0` is named for the usage doc but also backs `read_contract_doc/0`. The name undersells it; it's just "repo root from cwd."

## Functional evidence
- Criterion 1 — pass: `test_in_memory_store_writes_no_file_and_queries_unchanged` runs the full `start_link/0` lifetime inside a fresh temp dir, asserts the dir listing is unchanged before/after, and pins `all/1`=[a1,b1,a2], `by_run`=[a1,a2], `by_session`=[a1,a2], `by_correlation`=[a1,a2]. `soma_sup` still starts the store with `start_link, []` (apps/soma_runtime/src/soma_sup.erl:19), so the default path is untouched.
- Criterion 2 — pass: `test_persistent_store_creates_file_after_first_append` asserts `filelib:is_regular(Path)` is false before and true after the first `append/2` on a `start_link(#{log => Path})` store.
- Criterion 3 — pass: `test_appended_event_reads_back_from_log_as_normalized` stops the store, reopens its own `disk_log` at `Path`, reads the term, and asserts it equals the store's normalized view (`by_run/2` result). Append writes `normalize(Event)` to the log (soma_event_store.erl:91-94), so the on-disk term is the normalized map, not the raw input.
- Criterion 4 — pass: `test_restart_recovers_events_into_all` appends a1/b1/a2 to a store, stops it, starts a new store at the same path, asserts `all/1` types = [a1,b1,a2] and equals the pre-restart `all/1`. Index rebuilt by `replay_log/3` in `init/1`.
- Criterion 5 — pass: `test_by_run_after_restart_filters_to_one_run` appends across run_a/run_b, restarts, asserts `by_run(run_a)` types = [a1,a2] and equals the pre-restart result (b1 excluded).
- Criterion 6 — pass: `test_by_correlation_after_restart_returns_full_chain` appends corr_a under run_a/sess_a and run_c/sess_c plus a corr_b event, restarts, asserts `by_correlation(corr_a)` = [a1,a2] spanning two layers, equals pre-restart, b1 excluded.
- Criterion 7 — pass: `test_truncated_tail_boots_and_serves_intact_events` appends a1/b1, stops, appends garbage bytes to the file tail off-chain, restarts, asserts `init/1` returns and `all/1` = [a1,b1]. I ran a standalone probe: the garbage tail surfaces as the chunk loop reads `a1` then hits the bad bytes; the loop treats `{error, {corrupt_log_file, _}}` as end-of-log (soma_event_store.erl:80-81).
- Criterion 8 — pass: docs/usage.md:174-204 ("Persistent store and restart durability" under "## Reading events") documents `start_link/1`, the `log =>` path option, the restart-replay durability claim, and the corrupt-tail behavior. `test_usage_doc_documents_start_link_1_and_durability` asserts the prose and its position after the events heading.
- Criterion 9 — pass: docs/contracts/v0.6-test-contract.md exists and maps criteria 1-7 to their cases in `soma_event_store_persist_tests` (table at lines 54-62). `test_v0_6_contract_doc_maps_each_persistence_proof` asserts the suite name and all seven case names are present.
- Criterion 10 — pass: `rebar3 eunit` = 154 tests, 0 failures; `rebar3 ct` = All 193 tests passed.

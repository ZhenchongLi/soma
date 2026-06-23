### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `make_event_id/0` uses `ref_to_list(make_ref())`. A ref is unique within a running node, so the criterion-5 test holds. But a ref string is not stable across nodes or restarts and carries no ordering. Fine for an in-memory v0.1 store. When the run layer starts emitting events for real, decide whether downstream consumers need a sortable/portable id — a later issue, not a blocker here.
- `timestamp` is `erlang:system_time(nanosecond)`, an integer, not a UTC string. README lists `timestamp` as mandatory but doesn't pin the type. Consistent and monotonic-enough for ordering. Confirm the consumer format before the event log gets serialized anywhere.

## Nits
- `test_timestamp_filled_when_absent` asserts the same thing twice: `?assertNotEqual(undefined, Timestamp)` then `?assert(Timestamp =/= undefined)`. Second line is redundant.
- Three read clauses each call `lists:reverse(Events)`. `by_run`/`by_session` reverse the full list to filter — a forward-order helper would remove the repetition. O(n) either way; not worth it at v0.1 volumes.

## Functional evidence
- Criterion 1 — pass: `all_returns_append_order_test` appends `first/second/third`, `all/1` returns `[first, second, third]`. Store keeps events front-inserted and reverses once on read (`soma_event_store.erl:42,44`).
- Criterion 2 — pass: `by_run_filters_test` appends under `run_a/run_b/run_a`, `by_run(Pid, run_a)` returns `[a1, a2]` only.
- Criterion 3 — pass: `by_session_filters_test` appends under `sess_a/sess_b/sess_a`, `by_session(Pid, sess_a)` returns `[a1, a2]` only.
- Criterion 4 — pass: `event_has_all_eight_fields_test` appends an event without `step_id`/`tool_call_id`; read-back keys sort to all 8 mandatory keys, and omitted keys come back `undefined` (`normalize/1` foldl, `soma_event_store.erl:70-77`).
- Criterion 5 — pass: `event_id_unique_test` appends three events (two with identical payloads); `length(Ids) =:= length(usort(Ids))`. Ids minted per append by `make_event_id/0` (`soma_event_store.erl:62-65,79-80`).
- Criterion 6 — pass: `timestamp_filled_when_absent_test` appends with no `timestamp`; read-back `timestamp` is non-`undefined` (`normalize/1` stamps `system_time(nanosecond)`, `soma_event_store.erl:66-69`).
- Criterion 7 — pass: `empty_store_returns_empty_list_test` asserts `all/1`, `by_run/2`, `by_session/2` each return `[]` on a fresh store.
- Criterion 8 — pass: `store_survives_empty_query_test` queries empty `all/1` then asserts `is_process_alive(Pid) =:= true`.

Full run: `rebar3 eunit --module=soma_event_store_tests` → `8 tests, 0 failures`. Compiles clean under `warnings_as_errors`.

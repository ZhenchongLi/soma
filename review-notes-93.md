### Claude

## Verdict
changes-requested

## Real issues

1. **Every actor line in a real chain prints `step_id=undefined`.**
   `soma_trace.erl:34` uses `maps:find(step_id, Event)`. The store's
   `normalize/1` (`apps/soma_event_store/src/soma_event_store.erl:64-84`) lists
   `step_id` in `MANDATORY_KEYS` and force-fills every stored event with
   `step_id => undefined`. So `maps:find` returns `{ok, undefined}` on every
   actor event, and the line gets ` step_id=undefined`.

   The driven chain in criterion 7 has four actor events. `render/2` renders all
   four with `step_id=undefined` glued on. Proof, run against the built code:

   ```
   actor.started task_id=t1 step_id=undefined
   run.started step_id=s1
   ```

   This is the headline output the tool exists to produce, and the noise lands
   on every actor line.

   It also breaks the contract shipped in the same diff: `docs/usage.md:419-421`
   says "a field the event does not carry is left off rather than printed empty,"
   and `design-93.md:38-40` says the same. The code does the opposite.

   The CT and EUnit tests miss it because they only assert substring presence of
   `event_type` / id / reason, never the absence of `=undefined`. Fix: treat a
   present-but-`undefined` field the same as a missing one (the `task_id` branch
   has the identical hole — it survives only because `task_id` is not in
   `MANDATORY_KEYS`, so it is one emitter change away from the same bug).

## Questions

None.

## Nits

- `render/2`'s spec says `Store :: pid()` (`soma_trace.erl:19`). The store can
  also be a registered name. Widen to `pid() | atom()` or drop the narrowing.
- Comments restate the obvious ("Sort by timestamp using a custom comparator
  that handles maps", `soma_trace.erl:9`). The code already says that.

## Functional evidence
- Criterion 1 — pass: `timeline_one_line_per_event_test` asserts 3 events → 3 non-empty lines (`apps/soma_event_store/test/soma_trace_tests.erl:5-15`).
- Criterion 2 — pass: `timeline_orders_by_timestamp_test` feeds 300/100/200, asserts output `["event_first","event_second","event_third"]` (`soma_trace_tests.erl:20-31`).
- Criterion 3 — pass: `timeline_line_names_event_type_test` asserts the line contains `tool.invoked` (`soma_trace_tests.erl:36-43`).
- Criterion 4 — pass: `timeline_line_includes_task_id_test` asserts the line contains `task-abc-123` (`soma_trace_tests.erl:48-55`).
- Criterion 5 — pass (value present), but see Real issue 1: `timeline_line_includes_step_id_test` asserts `step-xyz-456` appears (`soma_trace_tests.erl:60-67`); the value lands, but events without a `step_id` print `step_id=undefined` instead of omitting it.
- Criterion 6 — pass: `timeline_failure_reason_from_top_and_payload_test` asserts top-level reason `bang` and payload reason `crash` both land (`soma_trace_tests.erl:72-86`).
- Criterion 7 — pass: `test_render_driven_chain_is_ordered_and_terminal` drives an actor `run_steps` task to `actor.task.completed`, asserts line count equals event count, lines in timestamp order, last line terminal (`apps/soma_actor/test/soma_actor_correlation_SUITE.erl:82-122`).
- Criterion 8 — pass: `render_unknown_correlation_is_empty_test` asserts `render(Store, <<"no-such-id">>)` returns `<<>>` without crashing (`soma_trace_tests.erl:91-95`).
- Criterion 9 — pass: `no_dependency_on_actor_or_runtime_test` scans `soma_trace.erl` source for `soma_actor` / `soma_runtime` (0 occurrences) and calls `timeline/1` on a plain map list with no processes (`soma_trace_tests.erl:100-116`); `soma_trace.erl` exports/imports confirm no actor/runtime reference.
- Criterion 10 — pass: `docs/usage.md:402-427` adds "Tracing: render a correlation chain as a readable timeline" showing `soma_trace:render(StorePid, CorrelationId)`; `doc_has_tracing_section_with_render_call_test` asserts the heading and call exist (`apps/soma_tools/test/soma_usage_tracing_doc_tests.erl`).
- Criterion 11 — pass: `rebar3 eunit` → 144 tests, 0 failures; `rebar3 ct` → All 193 tests passed.

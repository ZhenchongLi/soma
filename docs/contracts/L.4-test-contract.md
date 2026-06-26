# L.4 Test Contract — term→Lisp renderer (Erlang terms render as Lisp s-exprs)

This document maps each behavioural property of the L.4 term→Lisp renderer slice
(issue #112) to the test that proves it. It is the inverse companion to
[L.1-test-contract.md](L.1-test-contract.md) — the Lisp-envelope slice that
taught `soma_lfe` to parse Lisp into Erlang terms — and to
[v0.6-test-contract.md](v0.6-test-contract.md), whose `soma_trace` read-side
trace tooling L.4 extends with a Lisp-rendering variant (`render_lisp/2`).

The slice adds a pure renderer `soma_lisp:render/1 -> iodata()` in
`apps/soma_event_store/src/soma_lisp.erl` — the inverse of the parse mapping:
atom→symbol (with `_`→`-` so envelopes round-trip), binary→quoted string,
number→text, list→`(elem ...)`, map→tagged pair-list form, and a
non-renderable value (pid/ref/fun/port) falls through to an
`io_lib:format("~p", ...)` quoted string so the renderer never crashes.
`soma_trace:render_lisp/2` fetches a correlation chain via `by_correlation/2`,
sorts by timestamp ascending, and renders one s-expr per event. The renderer is
pure: it opens no LLM call and no network socket.

## Pure renderer (term → Lisp s-expr)

These are direct, pure-function proofs: `soma_lisp:render/1` called with a term
literal, no processes and no events.

| Property | Test module | Test name |
|----------|-------------|-----------|
| 1 — a result map renders to the fixed `(result (status ...) (outputs ...) (correlation-id ...))` s-expr | `soma_lisp_tests` | `test_render_result_map_produces_fixed_sexpr` |
| 2 — an event map renders to an `event`-headed s-expr whose sub-forms carry the event's fields | `soma_lisp_tests` | `test_render_event_map_carries_fields` |
| 3 — a pid renders as a quoted string (the `~p` text) and never crashes | `soma_lisp_tests` | `test_render_pid_becomes_quoted_string` |
| 5 — a `(msg ...)` envelope round-trips: parse → render → re-parse equals the original parsed term | `soma_lisp_tests` | `test_msg_envelope_round_trips_through_render` |

## Trace render (correlation chain → Lisp, timestamp ascending)

This drives the read-side render chain — `soma_trace:render_lisp/2` →
`soma_event_store:by_correlation/2` → sort by timestamp → `soma_lisp:render/1`
per event — against a live event store seeded with one shared `correlation_id`
and out-of-order timestamps, asserting one `event`-headed s-expr per event in
ascending timestamp order.

| Property | Test suite | Test case |
|----------|------------|-----------|
| 4 — `render_lisp/2` renders a correlation chain as a Lisp trace, timestamp ascending, one s-expr per event | `soma_trace_lisp_SUITE` | `test_render_lisp_orders_chain_by_timestamp` |

## Contract doc (this file)

| Property | Test module | Test name |
|----------|-------------|-----------|
| 6 — `docs/contracts/` gains an L.4 entry mapping each proof to its suite and case | `soma_l4_contract_doc_tests` | `test_doc_names_l4_suites_and_cases` |

## Mock-only guard (no real LLM, no network socket)

This source-level guard pins the L.4 test sources to the pure renderer only — no
real-provider marker (`soma_llm_openai`, `api_key`, `base_url`, `http`,
`https`, socket open) appears — so the gate (`rebar3 eunit && rebar3 ct`) never
opens a real LLM call or network socket.

| Property | Test module | Test name |
|----------|-------------|-----------|
| 7 — no real-provider marker or socket open appears in the L.4 test sources | `soma_l4_mock_only_tests` | `test_no_real_provider_or_socket_in_l4_tests` |

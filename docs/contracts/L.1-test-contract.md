# L.1 Test Contract — Lisp envelope (`soma_lfe` parses `(msg ...)`, `soma_actor` accepts a Lisp message)

This document maps each behavioural property of the L.1 Lisp-envelope slice
(issue #103) to the test that proves it. It is the companion to
[v0.3-test-contract.md](v0.3-test-contract.md) — the DSL compiler contract this
slice extends — and serves as the barrier that keeps the Lisp boundary at the
edge: the actor's message contract stays map-only, and the runtime never learns
Lisp exists.

The slice adds a `(msg ...)` parse path to `soma_lfe:compile/2` (turning a Lisp
message form into the existing `#{type, payload, steps?, llm?, correlation_id?}`
envelope map) and lets `soma_actor:send/2` / `ask/3` accept a string or binary
argument by compiling it through `soma_lfe:compile/2` before the
`gen_statem:call`. A map argument keeps the existing path untouched.

## Parser boundary (`(msg ...)` → envelope map)

These are direct parser-level proofs: `soma_lfe:compile/2` →
`soma_lfe_reader:read_forms/1` → the `soma_lfe_parser` `msg` path. No processes,
no events.

| Property | Test module | Test name |
|----------|-------------|-----------|
| 1 — `(msg ...)` with type/payload/steps parses to the hand-written envelope map | `soma_lfe_message_tests` | `test_msg_form_produces_envelope_map` |
| 2 — `(msg ...)` with `correlation-id` and `llm` fills those envelope fields | `soma_lfe_message_tests` | `test_msg_form_carries_correlation_id_and_llm` |
| 3 — malformed `(msg ...)` returns `{error, [Diagnostic]}` with `message`/`line`, no crash | `soma_lfe_message_tests` | `test_malformed_msg_returns_diagnostics` |
| 4 — top-level `(run ...)` still returns the pre-slice `{ok, #{run => #{steps => Steps}}}` shape | `soma_lfe_message_tests` | `test_run_form_unchanged_after_msg_added` |

## Actor integration (Lisp `send/2` / `ask/3`, end-to-end)

These tests prove a Lisp message drives the full actor path —
`soma_actor:send/2` / `ask/3` (binary arg) → `soma_lfe:compile/2` →
`gen_statem:call` → `idle/3` → `soma_run` terminal — producing the same outputs,
correlation chain, and survival semantics as the equivalent map envelope, and
that a malformed Lisp string never reaches the actor.

| Property | Test module | Test name |
|----------|-------------|-----------|
| 5 — Lisp `send/2` produces the same run outputs as the map `send/2` | `soma_actor_lisp_message_SUITE` | `test_lisp_send_matches_map_send_outputs` |
| 6 — Lisp `send/2` correlation chain matches the map `send/2` chain (`by_correlation/2`) | `soma_actor_lisp_message_SUITE` | `test_lisp_send_correlation_chain_matches_map` |
| 7 — malformed Lisp `send/2` returns `{error, _}` and the actor survives (accepts a valid map next) | `soma_actor_lisp_message_SUITE` | `test_malformed_lisp_send_actor_survives` |
| 8 — Lisp `ask/3` returns the same result as the map `ask/3` | `soma_actor_lisp_message_SUITE` | `test_lisp_ask_matches_map_ask_result` |
| 9 — a map envelope `send/2` still runs unchanged (never touching `soma_lfe`) | `soma_actor_lisp_message_SUITE` | `test_map_send_path_untouched` |

## Contract doc (this file)

| Property | Test module | Test name |
|----------|-------------|-----------|
| 10 — `docs/contracts/` gains an L.1 entry mapping each proof to its suite and case | `soma_l1_contract_doc_tests` | `test_doc_names_parser_suite_and_cases`, `test_doc_names_actor_suite_and_cases` |

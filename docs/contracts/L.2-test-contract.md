# L.2 Test Contract — Actor-to-actor Lisp (a Lisp `(msg ...)` body delivered between actors)

This document maps each behavioural property of the L.2 actor-to-actor Lisp
slice (issue #107) to the test that proves it. It is the companion to
[L.1-test-contract.md](L.1-test-contract.md) — the Lisp-envelope slice this one
extends — and to [v0.5-test-contract.md](v0.5-test-contract.md), whose
`actor_message` proposal path L.2 reuses.

The slice lets one actor (A1) deliver an approved `actor_message` proposal whose
*body* is a Lisp `(msg ...)` string carrying steps to a second actor (A2). A2
parses the Lisp at its own `soma_actor:send/2` string clause — the L.1 path —
and runs the steps. No new actor message contract is added: the body is either
the existing map envelope (the v0.5.6 path, untouched) or a Lisp string that
compiles to that same map before delivery. The runtime never learns Lisp exists.

## Actor-to-actor Lisp delivery (end-to-end)

All L.2 proofs live in a single suite, `soma_actor_lisp_to_lisp_SUITE`. Each
boots the `soma_runtime` app (shared event store and `soma_run_sup` alive),
starts two actors through `soma_actor_sup:start_actor/1`, and drives A1 through
the real `soma_actor:send/2` with a `proposal` mock LLM directive — the full
decision-to-delivery chain, no layer bypassed, mock LLM only.

| Property | Test suite | Test case |
|----------|------------|-----------|
| 1 — a Lisp `(msg ...)` body drives the receiver to the same terminal status as the equivalent map body | `soma_actor_lisp_to_lisp_SUITE` | `lisp_body_reaches_same_terminal_status_as_map` |
| 2 — the receiver's run for a Lisp body produces the same step outputs as the run for the equivalent map body | `soma_actor_lisp_to_lisp_SUITE` | `lisp_body_produces_same_step_outputs_as_map` |
| 3 — `by_correlation/2` on the sender's id returns both the sender's and the receiver's events for a Lisp body | `soma_actor_lisp_to_lisp_SUITE` | `by_correlation_spans_both_actors_for_lisp_body` |
| 4 — a malformed Lisp body leaves a terminal `failed` sender task with no crash | `soma_actor_lisp_to_lisp_SUITE` | `malformed_lisp_body_marks_task_failed` |
| 5 — after a malformed Lisp body fails a sender task, the receiving actor is still alive and accepts a following valid message | `soma_actor_lisp_to_lisp_SUITE` | `actor_alive_and_accepts_after_malformed_body` |
| 6 — a map-bodied `actor_message` still delivers and runs unchanged (the v0.5.6 path, never touching `soma_lfe`) | `soma_actor_lisp_to_lisp_SUITE` | `map_body_path_unchanged` |

## Contract doc (this file)

| Property | Test module | Test name |
|----------|-------------|-----------|
| 7 — `docs/contracts/` gains an L.2 entry mapping each proof to its suite and case | `soma_l2_contract_doc_tests` | `test_doc_names_lisp_to_lisp_suite_and_cases` |

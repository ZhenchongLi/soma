# L.3 Test Contract — Lisp proposals (the mock LLM emits a Lisp s-expr proposal)

This document maps each behavioural property of the L.3 Lisp-proposal slice
(issue #109) to the test that proves it. It is the companion to
[L.1-test-contract.md](L.1-test-contract.md) — the Lisp-envelope slice that
moved the message boundary to Lisp — and to
[v0.5-test-contract.md](v0.5-test-contract.md), whose proposal decision chain
(`proposal.created` → `soma_policy:check/2` → `proposal.approved`/`rejected` →
execute/complete) L.3 reuses unchanged.

The slice teaches `soma_lfe` to parse proposal forms — `(reply ...)`,
`(run-steps ...)`, `(reject ...)`, `(ask ...)`, `(actor-message ...)` — each
into the exact `#{kind => ...}` map `soma_proposal:normalize/1` already accepts,
and teaches the actor's `proposal_result/1` to compile a string LLM output
through `soma_lfe:compile/2` before that normalize step. The mock LLM stays the
only provider; the worker still returns its `output` verbatim, so the Lisp parse
happens actor-side at the boundary. A map output keeps the v0.5 path untouched.

## Parser boundary (proposal form → proposal map)

These are direct parser-level proofs: `soma_lfe:compile/2` →
`soma_lfe_reader:read_forms/1` → `soma_lfe:dispatch/1` →
`soma_lfe_parser:parse_proposal/1`, with the result fed to
`soma_proposal:normalize/1`. No processes, no events.

| Property | Test module | Test name |
|----------|-------------|-----------|
| 1 — `(reply (text "hi"))` parses to a map that normalizes to a `reply` proposal | `soma_lfe_proposal_tests` | `test_reply_form_normalizes_to_reply_kind` |
| 2 — `(run-steps (step ...))` parses to a `run_steps` proposal with steps equivalent to the L.1 run path | `soma_lfe_proposal_tests` | `test_run_steps_form_normalizes_with_equivalent_steps` |
| 3 — a malformed proposal form returns `{error, [Diagnostic]}` with `message`/`line`, no crash | `soma_lfe_proposal_tests` | `test_malformed_proposal_form_returns_diagnostic` |

### The `(reject (reason ...))` form (issue #138)

`(reject (reason "..."))` is the third Lisp proposal form. It compiles to
`#{kind => reject, reason => <<...>>}` — the reason string becomes a binary —
and normalizes through `soma_proposal:normalize/1`'s existing reject clause. A
malformed `(reject (reason))` (no reason string) does not match the reject
clause and falls through the existing catch-all to a diagnostic carrying a
binary `message` and a `line` key, without crashing. These proofs route through
the same `soma_lfe:compile/2` → `soma_lfe:dispatch/1` → `parse_proposal/1`
boundary as the `reply` / `run-steps` forms above.

| Property | Test module | Test name |
|----------|-------------|-----------|
| `(reject (reason "..."))` compiles to a `reject` map with a binary reason | `soma_lfe_proposal_tests` | `test_reject_form_compiles_to_reject_kind` |
| the compiled reject map normalizes through `soma_proposal:normalize/1` to a `reject` proposal | `soma_lfe_proposal_tests` | `test_reject_form_normalizes_to_reject_kind` |
| a malformed `(reject (reason))` returns a diagnostic (binary `message`, `line` key), no crash | `soma_lfe_proposal_tests` | `test_malformed_reject_form_returns_diagnostic` |
| `docs/contracts/L.3-test-contract.md`, `docs/lfe-dsl.md`, `docs/lisp-messages.md` document the reject form | `soma_lfe_reject_doc_tests` | `test_docs_document_reject_form` |

## Actor integration (Lisp proposal, end-to-end)

These tests drive the full decision chain — `soma_actor:send/2` → `idle/3` →
`soma_llm_call` `proposal` directive (a Lisp string output) → `proposal_result/1`
→ `soma_lfe:compile/2` → `soma_proposal:normalize/1` → `soma_policy:check/2` →
execute/complete — with the mock LLM only, and prove a Lisp proposal reaches the
same terminal result as the equivalent map proposal, that a `run-steps` proposal
emits `proposal.executed` and runs, that a malformed Lisp proposal fails the task
as data while the actor stays alive, and that the v0.5 raw-map path is unchanged.

| Property | Test suite | Test case |
|----------|------------|-----------|
| 4 — a mock Lisp `(reply ...)` reaches the same terminal result as the map reply | `soma_actor_lisp_proposal_SUITE` | `lisp_reply_reaches_same_terminal_result_as_map_reply` |
| 5 — a mock Lisp `(run-steps ...)` emits `proposal.executed` and runs to a terminal result | `soma_actor_lisp_proposal_SUITE` | `lisp_run_steps_emits_proposal_executed_and_runs` |
| 6 — a malformed Lisp proposal fails the task as data, the actor stays alive and accepts a following valid message | `soma_actor_lisp_proposal_SUITE` | `malformed_lisp_proposal_fails_task_actor_alive` |
| 7 — a raw-map proposal still normalizes, gates, and executes unchanged (never touching `soma_lfe`) | `soma_actor_lisp_proposal_SUITE` | `map_proposal_path_unchanged` |

## Contract doc (this file)

| Property | Test module | Test name |
|----------|-------------|-----------|
| 8 — `docs/contracts/` gains an L.3 entry mapping each proof to its suite and case | `soma_l3_contract_doc_tests` | `test_doc_names_l3_suites_and_cases` |

## Mock-only guard (no real LLM, no network socket)

These source-level guards pin the L.3 actor suite to the mock `proposal`
directive only — the same way `soma_l2_mock_only_tests` does for L.2 — so the
gate (`rebar3 eunit && rebar3 ct`) never opens a real LLM call or network socket.

| Property | Test module | Test name |
|----------|-------------|-----------|
| 9a — every `directive =>` in the L.3 actor suite is `directive => proposal` (mock only) | `soma_l3_mock_only_tests` | `test_every_llm_directive_is_the_proposal_mock` |
| 9b — no real-provider marker (`soma_llm_openai`, `api_key`, `base_url`, `http`, `https`) appears in the L.3 actor suite | `soma_l3_mock_only_tests` | `test_no_real_provider_config_in_suite` |

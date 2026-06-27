# CLI.2 Test Contract — `soma ask` agent command (intent → LLM → proposal → result, mock on gate)

This document maps each proof of the CLI.2 slice (issue #122) to the suite or
module and the case that proves it. It is the companion to
[cli-1b-test-contract.md](cli-1b-test-contract.md) and
[cli-test-contract.md](cli-test-contract.md), and follows the same shape as the
v0.x contracts ([v0.5-test-contract.md](v0.5-test-contract.md),
[v0.6-test-contract.md](v0.6-test-contract.md)).

## What this slice builds

The CLI gains an agent command. `soma ask "intent"` wraps the intent in an
`(ask (intent "..."))` s-expr and ships it to the daemon; `soma_cli_server`
compiles it with `soma_lfe:compile/2` (a new `(ask …)` form parsed by
`soma_lfe_parser:parse_ask/1` into `#{ask => #{intent => …, tool_policy => …,
budget => …}}`), starts a `soma_actor` under `soma_actor_sup`, and drives the
decision loop via `soma_actor:ask/3` (intent → mock `soma_llm_call` →
`soma_proposal:normalize/1` → `soma_policy:check/2` → terminal answer). The
server shapes the actor's return into a `(result …)` for `soma_lisp:render/1`: a
`reply` proposal completes with the reply text under `(outputs …)`, a `reject`
yields a `rejected` status carrying the reason, and a `(budget-llm 0)` refusal
yields a non-`completed` result carrying `{budget_exceeded, max_llm_calls}`. The
CLI modules (`soma_cli`, `soma_cli_server`) and their tests move up from
`apps/soma_runtime/` into `apps/soma_actor/` so the server can see both the run
path and the actor without inverting the one-way dependency. The gate uses mock
directives only — no real provider, no non-local socket. See
[../../design-122.md](../../design-122.md).

## Proving suites and modules

- **`soma_lfe_ask_tests`** — EUnit module in `apps/soma_lfe/test/`. Exercises the
  pure compile boundary `soma_lfe:compile/2` on the new `(ask …)` form (parse,
  required-field error, allow + budget sub-forms).
- **`soma_cli_server_SUITE`** — CT suite in `apps/soma_actor/test/`. Drives the
  full ask chain through a real `gen_tcp` client over a temp Unix socket: accept
  loop → `handle/1` → `handle_lisp_request/2` → `soma_lfe:compile/2` →
  `soma_actor_sup:start_actor` → `soma_actor:ask/3` → mock `soma_llm_call` →
  `soma_proposal:normalize/1` → `soma_policy:check/2` → `soma_lisp:render/1` →
  framed reply. No layer bypassed.
- **`soma_cli_SUITE`** — CT suite in `apps/soma_actor/test/`. Drives the
  `soma_cli` client (`ask/1`) against a real `soma_cli_server` on a temp socket
  whose mock yields a `reply` proposal.
- **`soma_cli_2_marker_tests`** — EUnit module in `apps/soma_actor/test/`. A
  source scan of the CLI.2 test files for real-provider / non-local-socket
  markers.
- **`soma_cli_2_contract_tests`** — EUnit module in `apps/soma_actor/test/`.
  Pins this contract doc (`docs/contracts/cli-2-test-contract.md`): asserts the
  file exists, is non-empty, and names every CLI.2 suite/module together with
  each of its case names.

## CLI.2 proofs → cases

| Criterion | Proof | Suite / module | Case |
| --- | --- | --- | --- |
| 1 | `soma_lfe:compile/2` on `(ask (intent "..."))` returns `{ok, #{ask => #{intent => <<"...">>}}}` | `soma_lfe_ask_tests` | `test_ask_intent_parses_to_ask_map` |
| 2 | `soma_lfe:compile/2` on an `(ask …)` with no `(intent …)` returns `{error, [Diagnostic]}`, not a malformed ok map | `soma_lfe_ask_tests` | `test_ask_without_intent_returns_error` |
| 3 | `soma_lfe:compile/2` on `(ask (intent "x") (allow echo file_read) (budget-llm 3) (budget-steps 5))` parses the allow list and budget | `soma_lfe_ask_tests` | `test_ask_allow_and_budget_parse` |
| 4 | A mock-`reply` ask request drives the decision loop and the framed `(result …)` is `completed` and carries the reply text | `soma_cli_server_SUITE` | `test_ask_reply_returns_completed_result_with_text` |
| 5 | A mock-`reject` ask request yields a `(result …)` whose status is `rejected` and which carries the reject reason | `soma_cli_server_SUITE` | `test_ask_reject_returns_rejected_result_with_reason` |
| 6 | A `(ask (intent "…") (budget-llm 0))` request drives a non-`completed` result carrying `{budget_exceeded, max_llm_calls}` | `soma_cli_server_SUITE` | `test_ask_budget_llm_zero_returns_budget_exceeded` |
| 7 | `soma_cli:ask/1` against a mock-`reply` server sends an intent, prints the `(result …)`, returns exit 0 | `soma_cli_SUITE` | `test_ask_prints_reply_result_exit_zero` |
| 8 | `docs/cli.md` documents the finalized `soma ask` flow (`(ask …)` request, `(result …)` reply, mock-on-gate vs real-provider-by-config) | _docs deliverable_ | the prose in `docs/cli.md` (no test function; pinned by `soma_cli_md_ask_tests`) |
| 9 | This contract (`docs/contracts/cli-2-test-contract.md`) names a suite/module + case for each CLI.2 proof | `soma_cli_2_contract_tests` | `test_doc_names_cli_2_suites_and_cases` (the mapping table above is the deliverable) |
| 10 | CLI.2 test sources carry no real-provider marker and open no non-local socket | `soma_cli_2_marker_tests` | `test_cli_2_sources_have_no_real_provider_or_socket_marker` |

## Notes for the auditor

- **Criteria 8 and 9 are docs deliverables.** Criterion 9 is this file itself; it
  is pinned by `soma_cli_2_contract_tests:test_doc_names_cli_2_suites_and_cases`,
  which fails if any suite/module or case name above goes missing. Criterion 8 is
  satisfied by the prose in `docs/cli.md` describing the `soma ask` flow — the
  Lisp `(ask …)` request, the `(result …)` reply, and mock-on-gate vs
  real-provider-by-config; that prose is additionally pinned by
  `soma_cli_md_ask_tests`.
- **The mock is the gate default.** Every CLI.2 server/client case is driven by a
  server-side `model_config` mock directive (`reply` / `reject`), never by a real
  provider — the same bar CLI.1b held. `soma_cli_2_marker_tests` guards it.
- **The `soma` escript/release entry is thin glue** over `soma_cli` and is
  exercised by the end-to-end path, not unit-tested, per the issue's out-of-scope
  note.

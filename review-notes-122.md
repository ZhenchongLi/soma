### Claude

## Verdict
approve

## Real issues

None.

## Questions

- The previous round's `parse_ask_fields/2` crash is fixed. Lines 156-165 of
  `apps/soma_lfe/src/soma_lfe_parser.erl` now end in a non-binary-intent clause
  (`malformed_form`) and a catch-all (`unknown_form`), both returning a
  diagnostic. `soma_lfe_ask_tests:test_ask_unknown_subform_returns_error` and
  `test_ask_non_binary_intent_returns_error` cover them. Nothing open.
- `soma_cli:ask/1` wraps the raw intent in quotes with no escaping
  (`ask_source/1`, `apps/soma_actor/src/soma_cli.erl:43`). An intent with a `"`
  breaks the s-expr the daemon parses. Single-user local CLI, user's own input —
  small blast radius. Is shipping unescaped quotes the intended contract, or
  should `ask_source/1` escape `"` / `\`?

## Nits

- `docs/cli.md` shows the reply example as `(outputs "the build failed …")` — a
  bare string. `handle_ask/2` renders `outputs => #{reply => Text}`, so the wire
  shape is `(outputs (reply "…"))`. The prose example understates the actual
  shape. Illustrative, not load-bearing.

## Functional evidence
- Criterion 1 — pass: `soma_lfe_ask_tests:test_ask_intent_parses_to_ask_map` asserts `soma_lfe:compile(<<"(ask (intent \"summarize the logs\"))">>, #{})` equals `{ok, #{ask => #{intent => <<"summarize the logs">>}}}`; EUnit green (214 tests, 0 failures).
- Criterion 2 — pass: `soma_lfe_ask_tests:test_ask_without_intent_returns_error` asserts `(ask)` compiles to `{error, [_|_]}`; the missing-intent branch in `parse_ask_fields/2` returns a `missing_required_field` diagnostic. Unknown sub-forms and non-binary intents now also return diagnostics (catch-all at `soma_lfe_parser.erl:156-165`), covered by `test_ask_unknown_subform_returns_error` and `test_ask_non_binary_intent_returns_error`.
- Criterion 3 — pass: `soma_lfe_ask_tests:test_ask_allow_and_budget_parse` asserts `(ask (intent "x") (allow echo file_read) (budget-llm 3) (budget-steps 5))` compiles to `tool_policy => #{allowed_tools => [echo, file_read]}` and `budget => #{max_llm_calls => 3, max_steps => 5}`.
- Criterion 4 — pass: `soma_cli_server_SUITE:test_ask_reply_returns_completed_result_with_text` drives a real gen_tcp client over a temp Unix socket with mock `model_config = #{directive => proposal, output => #{kind => reply, text => <<"the answer">>}}`; reply matches `^\(result `, `\(status completed\)`, and `the answer`; CT green (246 tests, 0 failures).
- Criterion 5 — pass: `soma_cli_server_SUITE:test_ask_reject_returns_rejected_result_with_reason` drives a mock yielding `#{kind => reject, reason => <<"cannot help with that">>}`; reply matches `\(status rejected\)` and `cannot help with that`. `handle_ask/2` renders the reject proposal as `status => rejected`, `error => Reason`.
- Criterion 6 — pass: `soma_cli_server_SUITE:test_ask_budget_llm_zero_returns_budget_exceeded` sends `(ask (intent "…") (budget-llm 0))`; reply is non-`completed`, carries `(error …)`, `budget_exceeded`, and `max_llm_calls`. The `max_llm_calls => 0` cap refuses the call before any LLM call starts.
- Criterion 7 — pass: `soma_cli_SUITE:test_ask_prints_reply_result_exit_zero` points `soma_cli:ask/1` at a real server on a temp socket with a `reply` mock; captured stdout matches `^\(result `, `\(status completed\)`, `the answer`, and exit code is `0`.
- Criterion 8 — pass: `docs/cli.md` `## soma ask` section documents the `(ask …)` request (required `(intent …)`, optional `(allow …)` / `(budget-llm N)` / `(budget-steps N)`), the `(result …)` reply (`completed` / `rejected` / `budget_exceeded`), and mock-on-gate vs real-provider-by-config; pinned by `soma_cli_md_ask_tests`.
- Criterion 9 — pass: `docs/contracts/cli-2-test-contract.md` exists and its proofs→cases table names a suite/module and a case for each of criteria 1–10; pinned by `soma_cli_2_contract_tests:test_doc_names_cli_2_suites_and_cases`.
- Criterion 10 — pass: `rebar3 eunit` green (214 tests) and `rebar3 ct` green (246 tests), 0 failures; `soma_cli_2_marker_tests:test_cli_2_sources_have_no_real_provider_or_socket_marker` scans CLI.2 sources for real-provider markers and non-`{local, _}` sockets and passes. `rebar3 dialyzer` reported 4 warnings, all pre-existing baseline (`soma_lfe_reader` lines 110/119/133, `soma_tool_call` line 114); none in the new CLI.2 code.

### Claude

## Verdict
changes-requested

## Real issues

- `parse_ask_fields/2` has no catch-all clause. An `(ask …)` form with any
  unrecognized sub-form, or a non-binary intent, crashes `soma_lfe:compile/2`
  with `function_clause` instead of returning `{error, [Diagnostic]}`.
  `apps/soma_lfe/src/soma_lfe_parser.erl:129-155`. Proof:
  `soma_lfe:compile(<<"(ask (intent \"x\") (frobnicate 1))">>, #{})` throws
  `{function_clause, [{soma_lfe_parser, parse_ask_fields, ...}]}`;
  `soma_lfe:compile(<<"(ask (intent 5))">>, #{})` throws the same.
  The module's `-spec compile/2 -> {ok, map()} | {error, [map()]}` promises a
  diagnostic, not a crash. Every sibling parser honors it: `parse_msg_step` and
  `parse_proposal` both end in catch-all clauses returning `unknown_form` /
  `malformed_proposal` diagnostics with a line number. `parse_ask` is the one
  form that breaks the contract. The CLI server hides it behind a try/catch in
  `handle_lisp_request/2`, so the daemon survives — but the pure boundary still
  lies, and a crash drops the line/diagnostic structure every other parse error
  carries. Add a non-binary-intent clause and a final catch-all returning an
  `unknown_form` diagnostic, the same shape `parse_msg_step` uses.

## Questions

- `soma_cli:ask/1` builds `(ask (intent "…"))` by wrapping the raw intent string
  in quotes with no escaping (`ask_source/1`,
  `apps/soma_actor/src/soma_cli.erl`). An intent containing a `"` breaks the
  s-expr the daemon parses. Single-user local CLI where the user trusts their own
  input, so the blast radius is small — but is leaving the client to ship
  unescaped quotes the intended contract, or should `ask_source/1` escape `"` /
  `\`?

## Nits

- `docs/cli.md` shows the reply example as `(outputs "the build failed …")` — a
  bare string. `handle_ask/2` renders `outputs => #{reply => Text}`, so the wire
  shape is `(outputs (reply "…"))`. The prose example understates the actual
  shape. Illustrative, not load-bearing.

## Functional evidence
- Criterion 1 — pass: `soma_lfe_ask_tests:test_ask_intent_parses_to_ask_map` asserts `soma_lfe:compile(<<"(ask (intent \"summarize the logs\"))">>, #{})` equals `{ok, #{ask => #{intent => <<"summarize the logs">>}}}`; EUnit green (212 tests, 0 failures).
- Criterion 2 — pass: `soma_lfe_ask_tests:test_ask_without_intent_returns_error` asserts `(ask)` compiles to `{error, [_|_]}`; the missing-intent branch in `parse_ask_fields/2` returns a `missing_required_field` diagnostic. (Note: this covers the missing-intent case the criterion names; unknown sub-forms crash instead — see Real issues.)
- Criterion 3 — pass: `soma_lfe_ask_tests:test_ask_allow_and_budget_parse` asserts `(ask (intent "x") (allow echo file_read) (budget-llm 3) (budget-steps 5))` compiles to `tool_policy => #{allowed_tools => [echo, file_read]}` and `budget => #{max_llm_calls => 3, max_steps => 5}`.
- Criterion 4 — pass: `soma_cli_server_SUITE:test_ask_reply_returns_completed_result_with_text` drives a real gen_tcp client over a temp Unix socket with mock `model_config = #{directive => proposal, output => #{kind => reply, text => <<"the answer">>}}`; reply matches `^\(result `, `\(status completed\)`, and `the answer`; CT green (246 tests, 0 failures).
- Criterion 5 — pass: `soma_cli_server_SUITE:test_ask_reject_returns_rejected_result_with_reason` drives a mock yielding `#{kind => reject, reason => <<"cannot help with that">>}`; reply matches `\(status rejected\)` and `cannot help with that`. `soma_actor:ask/3` returns the reject proposal as `{ok, #{kind => reject, reason => Reason}}`, which `handle_ask/2` renders as `status => rejected`.
- Criterion 6 — pass: `soma_cli_server_SUITE:test_ask_budget_llm_zero_returns_budget_exceeded` sends `(ask (intent "…") (budget-llm 0))`; reply is non-`completed`, carries `(error …)`, `budget_exceeded`, and `max_llm_calls`. `soma_actor.erl:571` calls `fail_task(TaskId, {budget_exceeded, max_llm_calls}, ...)` before any LLM call starts.
- Criterion 7 — pass: `soma_cli_SUITE:test_ask_prints_reply_result_exit_zero` points `soma_cli:ask/1` at a real server on a temp socket with a `reply` mock; captured stdout matches `^\(result `, `\(status completed\)`, `the answer`, and exit code is `0`.
- Criterion 8 — pass: `docs/cli.md` `## soma ask` section documents the `(ask …)` request (required `(intent …)`, optional `(allow …)` / `(budget-llm N)` / `(budget-steps N)`), the `(result …)` reply (`completed` / `rejected` / `budget_exceeded`), and mock-on-gate vs real-provider-by-config; pinned by `soma_cli_md_ask_tests`.
- Criterion 9 — pass: `docs/contracts/cli-2-test-contract.md` exists and its proofs→cases table names a suite/module and a case for each of criteria 1–10; pinned by `soma_cli_2_contract_tests:test_doc_names_cli_2_suites_and_cases`.
- Criterion 10 — pass: `rebar3 eunit && rebar3 ct` green (EUnit 212, CT 246, 0 failures); `soma_cli_2_marker_tests:test_cli_2_sources_have_no_real_provider_or_socket_marker` scans CLI.2 sources for real-provider markers and non-`{local, _}` sockets and passes. `rebar3 dialyzer` reported 4 warnings, all pre-existing baseline (`soma_lfe_reader` lines 110/119/133, `soma_tool_call` line 114); none in the new CLI.2 code.

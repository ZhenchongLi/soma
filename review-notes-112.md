### Claude

## Verdict
approve

## Real issues
None.

## Questions
- Full `rebar3 ct` flaked twice on `soma_cli_adapter_SUITE` (`test_cli_run_reaches_completed`, `test_cli_argv_semicolon_is_literal`) with `{error,timeout}` on the external CLI port spawn. The suite passes alone (14/14). This branch touches no CLI code — only `apps/soma_event_store`. It's the known cross-run external-process flake under full-gate load, not a renderer regression. Flagging so it doesn't surprise the merge gate; not a blocker for #112.
- `render/1` picks a map's head by key shape: result (`status`+`outputs`+`correlation_id`), then event (`event_type`), then envelope (`type`). The order is safe for the L.4 shapes — event maps carry `event_type` not `type`, so an envelope never gets misread. A future shape whose keys overlap would pick the wrong head. The design already calls this out as a known soft spot. No change needed now.

## Nits
- `render_value/1`'s single-key collapse (`#{value => <<"hi">>}` → `(value "hi")`) and the wrapped pair-list path are two map renderings living in `render_value`, while top-level `render/1` has a third map path. Three map-render rules across two functions. Reads fine today; worth folding if a fourth shape lands.

## Functional evidence
- Criterion 1 — pass: `iolist_to_binary(soma_lisp:render(#{status=>completed, outputs=>#{s1=>#{value=> <<"hi">>}}, correlation_id=> <<"c-7">>}))` produced `(result (status completed) (outputs ((s1 (value "hi")))) (correlation-id "c-7"))` — exact match. Atom→symbol, binary→quoted string, nested map→nested form. Proven by `soma_lisp_tests:test_render_result_map_produces_fixed_sexpr`.
- Criterion 2 — pass: rendering `#{event_type=>llm_started, task_id=> <<"t-1">>, step_id=> <<"s1">>}` produced `(event (event-type llm-started) (step-id "s1") (task-id "t-1"))` — `event`-headed, sub-forms carry each field. Proven by `soma_lisp_tests:test_render_event_map_carries_fields`.
- Criterion 3 — pass: rendering `#{pid=>self()}` produced `(pid "<0.10.0>")` and returned without crashing — pid rendered as a quoted `~p` string. Proven by `soma_lisp_tests:test_render_pid_becomes_quoted_string`.
- Criterion 4 — pass: `soma_trace:render_lisp/2` against a live store seeded with timestamps 300/100/200 under one correlation_id rendered three `(event ...)` forms ordered `event.a`(100) < `event.b`(200) < `event.c`(300). Proven by `soma_trace_lisp_SUITE:test_render_lisp_orders_chain_by_timestamp`.
- Criterion 5 — pass: parsing `(msg (type chat) (payload (text "hi")) (steps (step (id s1) (tool echo) (args (value "hi")))))` then rendering produced `(msg (type chat) (steps (step (args (value "hi")) (id s1) (tool echo))) (payload (text "hi")))`; re-parsing it through `soma_lfe:compile/2` returned a term equal to the original parsed envelope (`{ok,Env} =:= soma_lfe:compile(Rendered)` → `true`). Proven by `soma_lisp_tests:test_msg_envelope_round_trips_through_render`.
- Criterion 6 — pass: `docs/contracts/L.4-test-contract.md` added, mapping each proof to suite+case; `soma_l4_contract_doc_tests:test_doc_names_l4_suites_and_cases` asserts every suite/module and case name appears in the doc and is green.
- Criterion 7 — pass: `rebar3 eunit` green at 194/0. L.4 renderer/trace/doc tests are pure — `soma_l4_mock_only_tests:test_no_real_provider_or_socket_in_l4_tests` asserts zero `soma_llm_openai`/`api_key`/`base_url`/`http`/`https`/`gen_tcp`/`ssl:connect` markers across the L.4 sources and is green. (Full `ct` flaked on the unrelated `soma_cli_adapter_SUITE` external-port spawn under load; passes 14/14 in isolation — see Questions.)

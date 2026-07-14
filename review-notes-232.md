### Claude

## Verdict

approve

## Real issues

None.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: [x] `soma_config:load/1` maps `[llm] explore = true` to `explore => true` in the daemon model config. — `soma_config_tests:test_load_carries_explore_true` loads that setting from a temporary provider config and asserts `maps:get(explore, Config) =:= true`.
- Criterion 2 — pass: [x] One test proves a local socket ask uses positive `[llm] max_explore_rounds` and `[llm] max_observation_bytes` values as its actor round and observation budgets (one config fixture carrying both keys). — `soma_cli_server_SUITE:test_explore_ask_uses_configured_round_and_observation_budgets` loads limits `1` and `7`, observes one `llm.started`, and asserts the completed round retained seven bytes with `truncated => true`.
- Criterion 3 — pass: [x] Every invalid explore setting produces a diagnostic named after its config key (one test over the three keys). — `soma_config_tests:test_invalid_explore_settings_emit_keyed_diagnostics` captures the three exact `{invalid_llm_setting, Key, Expected}` warnings and asserts the rejected group is absent from the loaded map.
- Criterion 4 — pass: [x] An unparseable explore setting leaves the daemon reachable in non-explore mode (fail closed to explore-off). — `soma_cli_server_SUITE:test_unparseable_explore_setting_keeps_daemon_reachable_and_off` boots through `soma_cli:daemon/1`, gets a successful `soma_cli:ping/1`, and asserts the loaded map has no `explore` key.
- Criterion 5 — pass: [x] One end-to-end test: a fixed-response `soma ask` against a config-loaded explore daemon returns the terminal proposal result after one reader round, and that ask's second model request contains the bounded observation from the reader round. — `soma_cli_server_SUITE:test_config_loaded_explore_ask_returns_terminal_result_with_bounded_observation` gets exit `0` and the terminal reply text, captures request two, and matches its seven-byte truncated observation exactly.
- Criterion 6 — pass: [x] `soma trace` shows that ask's exploration rounds in event order. — `soma_cli_server_SUITE:test_trace_after_explore_ask_returns_rounds_in_event_order` enters through `soma_cli:ask/1` and `soma_cli:trace/1`, then asserts round events appear as `1 started`, `1 completed`, `2 started`, `2 completed`.
- Criterion 7 — pass: [x] Client socket closure cancels the actor task for an explore-mode ask. — `soma_cli_server_SUITE:test_explore_ask_client_disconnect_cancels_actor_task` waits for the reader tool to start, closes the raw client socket, and finds `actor.task.cancelled` under the same task and correlation ids.
- Criterion 8 — pass: [x] One test proves the three docmod example manifests normalize with honest effect metadata: `docmod_help` and `docmod_read` as reader/idempotent CLI tools with `{topic}` / `{input}` argv entries respectively, and `docmod_edit` as a state/non-idempotent CLI tool with `{input}` / `{changes}` argv entries. — `soma_tool_config_SUITE:test_docmod_example_manifests_normalize_with_expected_metadata` loads `examples/docmod-tools/` through `soma_tool_config:load_dir/1` and matches all three resolved descriptors, effects, idempotence flags, and argv lists.
- Criterion 9 — pass: [x] A stub-backed `docmod_help` run receives `help` followed by the substituted topic. — `soma_tool_config_SUITE:test_docmod_help_stub_receives_help_then_substituted_topic` patches only the example executable, runs it through a real session, and asserts `argc=2`, `arg1=help`, and `arg2=formatting`.
- Criterion 10 — pass: [x] One doc-pin test proves `docs/usage.md` documents the three explore settings for `soma ask` and the registration of the three docmod example manifests. — `soma_as4_contract_doc_tests:test_usage_documents_explore_settings_and_docmod_registration` reads the manual and pins all three settings, positive-limit and fail-closed text, all three example paths, the replacement path, and all three registration commands.
- Criterion 11 — pass: [x] `docs/contracts/AS.4-test-contract.md` maps every criterion to its proving test case. — `soma_as4_contract_doc_tests:test_as4_contract_maps_every_criterion_to_proving_case` asserts every Criterion 1–11 heading and its exact proving module/case occur once in the contract.

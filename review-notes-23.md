### Claude

## Verdict
approve

## Real issues

None.

## Questions

- The doc numbers its rows "Proof 1" through "Proof 9", but the issue criteria run 2 through 10. Proof 1 = criterion 2, and so on, with a one-off shift. Every row maps to the right test, so nothing is wrong — but a reader cross-checking the doc against the issue has to do the arithmetic. Worth a one-line note in the doc, or renumber to match.

## Nits

- `docs/v0.2-test-contract.md` "Coverage and the build gate" and "Drift caveat" repeat the same drift point made in `design-23.md`. Fine to keep; it's the doc that ships, not the design.

## Functional evidence
- Criterion 1 — pass: `docs/v0.2-test-contract.md` "The proof set" lists 9 proofs, each as a table naming suite + case + entry. All 18 named cases verified present by grep across the six suites.
- Criterion 2 — pass: Proof 1 maps to `soma_tool_manifest_tests:test_normalize_rejects_missing_shared_field` (reject) and `soma_tool_registry_tests:test_register_tool_rejects_missing_field_name_unresolvable` (does-not-resolve). Second case present at `apps/soma_tools/test/soma_tool_registry_tests.erl:48`, asserts `register_tool/1` returns `{error,_}` and `resolve_descriptor(ghost_tool)` returns `{error,not_found}`.
- Criterion 3 — pass: Proof 2 maps to `soma_run_happy_path_SUITE:test_registry_seeds_descriptors_from_manifests` (register through manifest) and `:test_multi_step_runs_sequentially_to_completed` (echo end-to-end). Both present, suite green in CT run.
- Criterion 4 — pass: Proof 3 maps to `soma_cli_adapter_SUITE:test_cli_run_reaches_completed`. Present; suite green.
- Criterion 5 — pass: Proof 4 maps to `soma_cli_adapter_SUITE:test_cli_tool_call_has_distinct_pid`. Present; suite green.
- Criterion 6 — pass: Proof 5 splits across `soma_cli_adapter_SUITE:test_cli_step_event_order` (asserts `tool.started < tool.succeeded < step.succeeded`, body confirmed) and `:test_cli_run_reaches_completed` (`run.completed`). The doc states the two-case split plainly.
- Criterion 7 — pass: Proof 6 maps to four `soma_cli_failure_SUITE` cases (`test_non_zero_exit_carries_status`, `test_missing_executable_named_error`, `test_missing_executable_reaches_run_failed_trail`, `test_non_executable_permission_error`) plus `test_session_alive_runs_new_run_after_cli_failure`. All present; suite green.
- Criterion 8 — pass: Proof 7 maps to `soma_cli_lifecycle_SUITE:test_cli_overrun_reaches_timeout` and `:test_cli_external_process_dead_after_timeout`. Latter body confirmed: 100ms step budget, 2s helper sleep, asserts `false = filelib:is_file(Marker)` after 3s — a leaked process would have written the marker.
- Criterion 9 — pass: Proof 8 maps to `soma_cli_lifecycle_SUITE:test_cli_cancel_reaches_cancelled` and `:test_cli_external_process_dead_after_cancel` (same marker-file liveness check). Both present; suite green.
- Criterion 10 — pass: Proof 9 maps to `test_session_alive_runs_new_cli_run_after_timeout`, `:after_cancel` (lifecycle suite) and `test_session_alive_runs_new_run_after_cli_failure` (failure suite). All present; suites green.
- Criterion 11 — pass: All 18 named cases resolve to existing functions (grep check, 18/18 OK). The one gap — does-not-resolve half of Proof 1 — is closed by the new `test_register_tool_rejects_missing_field_name_unresolvable` EUnit case.
- Criterion 12 — pass: `rebar3 eunit` → "72 tests, 0 failures"; `rebar3 ct` → "All 61 tests passed." CT covers the four cli suites; EUnit covers `soma_tool_manifest_tests` and `soma_tool_registry_tests`.
- Criterion 13 — pass: `README.md` "What v0.2 adds" section (diff lines added at :147) covers manifests, descriptor registry, cli adapter (lifecycle, failure normalization, argv/env/cwd safety), states out-of-scope (LFE DSL, MCP, LLM planner, DAG, persistent resume, open Linux x86_64+arm64 packaging), and links `docs/v0.2-test-contract.md` from the Docs list.

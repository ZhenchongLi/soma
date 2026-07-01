# CLI Real Planning Test Contract

This document maps the CLI/config real-provider planning surface to the suites
and cases that prove it. It extends the actor-level planning proofs with the
product surface: `[llm] plan = true`, `soma daemon` startup diagnostics, and the
local socket `soma ask` path.

## What this slice builds

The actor already supports real-provider planning when `model_config` carries
`plan => true`: provider content is read as a Lisp `(run-steps ...)` proposal,
then re-enters `soma_lfe:compile/2`, `soma_proposal:normalize/1`,
`soma_policy:check/2`, budgets, and the owned `soma_run` execution path. This
slice exposes that path through daemon config and proves the CLI behavior:

- `soma_config:load/1` carries `plan => true` from `[llm] plan = true`.
- Non-empty `[llm]` config fails with named config errors when required provider
  fields are missing.
- `soma daemon` returns non-zero and prints a clear diagnostic when a configured
  provider lacks `SOMA_LLM_API_KEY`.
- A framed `(ask ...)` over the local Unix socket can run a fixed real-provider
  `(run-steps ...)` plan to completion when config enables planning.
- Planned tools still pass through the normal allowlist policy gate.
- Provider secrets are omitted from the rendered reply and every emitted event.

The gate stays hermetic: every real-provider CLI planning test uses the fixed
`response => {200, Body}` seam, so no live provider socket is opened.

## Proving suites and modules

- **`soma_config_tests`** — EUnit module in `apps/soma_actor/test/`. Proves
  config loading carries `plan => true` and reports named errors for missing
  `provider`, `base_url`, and `model`.
- **`soma_cli_main_tests`** — EUnit module in `apps/soma_actor/test/`. Proves
  `soma daemon` exits non-zero and prints a missing-`SOMA_LLM_API_KEY`
  diagnostic when provider config has no API key in the daemon environment.
- **`soma_cli_server_SUITE`** — CT suite in `apps/soma_actor/test/`. Drives real
  local socket asks against a planning-enabled real-provider config with a fixed
  provider `response` seam.
- **`soma_cli_real_planning_contract_tests`** — EUnit module in
  `apps/soma_actor/test/`. Pins this contract, the docs deliverables, and the
  fixed-response seam evidence.

## Proofs -> cases

| Criterion | Proof | Suite / module | Case |
| --- | --- | --- | --- |
| 1 | `soma_config:load/1` carries `plan => true` from `[llm] plan = true` | `soma_config_tests` | `test_load_carries_plan_true` |
| 2 | Missing `[llm] provider` reports a named config error | `soma_config_tests` | `test_load_missing_provider_named_error` |
| 3 | `openai_compat` missing `base_url` reports a named config error | `soma_config_tests` | `test_load_missing_openai_base_url_named_error` |
| 4 | `openai_compat` missing `model` reports a named config error | `soma_config_tests` | `test_load_missing_openai_model_named_error` |
| 5 | `soma daemon` returns non-zero when provider config lacks `SOMA_LLM_API_KEY` | `soma_cli_main_tests` | `test_daemon_missing_api_key_prints_diagnostic_nonzero` |
| 6 | `soma daemon` prints a diagnostic naming `SOMA_LLM_API_KEY` | `soma_cli_main_tests` | `test_daemon_missing_api_key_prints_diagnostic_nonzero` |
| 7 | A framed planning `(ask ...)` over the local socket returns planned `echo` step output when loaded config carries `plan => true` | `soma_cli_server_SUITE` | `test_ask_real_provider_plan_returns_step_outputs` |
| 8 | A framed planning `(ask ...)` rejects a planned tool outside `(allow ...)` | `soma_cli_server_SUITE` | `test_ask_real_provider_plan_rejects_disallowed_tool` |
| 9 | CLI planning gate tests use the fixed provider `response` seam for every real-provider planning config | `soma_cli_real_planning_contract_tests` | `test_cli_planning_tests_use_fixed_provider_response_seam` |
| 10 | A completed daemon planning ask omits `SOMA_LLM_API_KEY` from the rendered reply | `soma_cli_server_SUITE` | `test_real_provider_plan_api_key_leaks_nowhere` |
| 11 | A completed daemon planning ask omits `SOMA_LLM_API_KEY` from every emitted event | `soma_cli_server_SUITE` | `test_real_provider_plan_api_key_leaks_nowhere` |
| 12 | `docs/usage.md` describes `plan = true` | `soma_cli_real_planning_contract_tests` | `test_usage_docs_document_plan_true` |
| 13 | `docs/cli.md` shows the planned `soma ask` result shape | `soma_cli_real_planning_contract_tests` | `test_cli_docs_document_plan_true_and_result_shape` |
| 14 | This contract names the proving suite/module and case for each proof | `soma_cli_real_planning_contract_tests` | `test_doc_names_cli_real_planning_suites_and_cases` |

## Notes for the auditor

- The CLI planning tests load provider config through `soma_config:load/1`, then
  add only the fixed `response` seam in the test process. Config files do not
  carry provider responses.
- Planning remains a proposal path. A planned `(run-steps ...)` proposal must pass
  normalization, policy, and budget checks before any `soma_run` starts.
- This contract does not add effect-aware policy, MCP, planner memory, live
  provider tests, or release artifacts.

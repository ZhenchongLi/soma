### Claude

## Verdict
approve

## Real issues
None.

## Questions
- The widened `is_result_map/1` whitelist must track every CLI terminal status by hand. Add a new terminal status later, forget the list, and its status-only map renders headless again — the exact bug being fixed, moved one hop. The design's Risks section already calls this out. Not a blocker for #179; worth a comment near the status list pointing at `result_pairs/1` so the next person keeps them in step.
- `has_model/1` treats any map without `directive` or `provider` as no-model. Broader than the issue's named `undefined`/`#{}` shapes. Fine today — no valid config uses neither key. If a future mock config does, this guard rejects it as no-model. Flagged, not blocking.

## Nits
None.

## Functional evidence
- Criterion 1 — pass: `test_run_timeout_returns_result_with_status_timeout` (soma_cli_server_SUITE) sends `(run (step wait sleep (args (ms 3000)) (timeout_ms 500)))` over the real Unix socket and asserts the reply matches `^\(result ` and contains `(status timeout)`. Root fix: `is_result_map/1` now heads any terminal-status map; soma_lisp.erl:97-109. CT suite green, 36/36.
- Criterion 2 — pass: `test_ask_no_model_returns_named_no_model_configured` (soma_cli_server_SUITE) starts the server with no `model_config` key, sends `(ask (intent "what is the answer"))`, and asserts the reply matches `(status failed)`, `(error no-model-configured)`, and `nomatch` on `function_clause`. Guard `has_model/1` in soma_cli_server.erl:178-200 short-circuits before any actor or LLM call.
- Criterion 3 — pass: `test_server_serves_after_no_model_ask` (soma_cli_server_SUITE) sends the no-model ask on connection one, closes it, then sends an echo `(run (step s1 echo ...))` on a fresh connection to the same daemon and asserts `(status completed)`. The no-model path spawns nothing, so the listener is untouched. CT suite green, 36/36.

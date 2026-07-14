### Claude

## Verdict

changes-requested

## Real issues

- `parse_args/2` makes mixed bare `from_step` validation depend on source order at `apps/soma_lfe/src/soma_lfe_parser.erl:888-896`. Its singleton clause catches the form only when it is last. The generic key/value clause accepts it when another entry follows. `(invoke (api-version "1") (request-id "r") (tool (name echo) (args (from_step prior) (value 1))))` therefore compiles and normalizes, even though bare `from_step` must be the only arg entry. Rendering that canonical map emits `(value 1)` first, and recompilation returns `invalid_operation`. This admits a malformed operation and breaks the required round trip.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: - [x] A valid tool envelope yields `operation => #{kind => tool, step => #{id => RequestId, tool => Tool, args => Args}}` through `soma_lfe:compile/2` → `soma_service_envelope:normalize/1`, with every declared field preserved and the normalized map containing only `kind`, `api_version`, `request_id`, `operation`, `scope`, `deadline_ms`, `max_output_bytes`, `correlation_id`, `artifacts`. Artifact: `soma_service_envelope_tests:test_valid_tool_invoke_compiles_and_normalizes` calls both production boundaries, asserts the full nine-field result, and checks the exact key allowlist.
- Criterion 2 — pass: - [x] A valid steps envelope yields `operation => #{kind => steps, steps => Steps}` with the source-ordered canonical list, byte-identical to what the existing `(run-steps ...)` step production emits for the same step forms (one shared `parse_proposal_steps/1` production; one test). Artifact: `soma_service_envelope_tests:test_valid_steps_invoke_matches_run_steps_production` compares the two lists with `term_to_binary/1` and pins both parser branches to the private `parse_proposal_steps/1` helper.
- Criterion 3 — fail: - [x] One table-driven test proves each invalid envelope class returns its distinct bounded typed error — `missing_api_version`, `unsupported_api_version` (anything but binary `<<"1">>`), `missing_request_id`, `invalid_request_id`, `duplicate_field` (rejected at the compiler boundary), `unknown_field`, `invalid_operation` (anything but exactly one well-formed tool-or-steps operation), `invalid_budget` (`deadline_ms`/`max_output_bytes` outside positive integers), `scope_entry_too_large` (binary entries above 255 bytes), `invalid_artifacts`, `invalid_correlation_id` — and growing a rejected value to 64 KiB leaves its typed error byte-identical. Artifact: the production compiler accepts `(args (from_step prior) (value 1))`, and `soma_service_envelope:normalize/1` returns `{ok, _}` instead of the fixed `invalid_operation` error. The table omits this malformed-operation shape.
- Criterion 4 — fail: - [x] Every canonical invoke map survives the `soma_lisp:render/1` → `soma_lfe:compile/2` round trip without data loss. Artifact: compiling and normalizing `(invoke (api-version "1") (request-id "r") (tool (name echo) (args (from_step prior) (value 1))))` succeeds; rendering emits `(args (value 1) (from_step prior))`, and recompilation returns the fixed `invalid_operation` diagnostic instead of the canonical map.
- Criterion 5 — pass: - [x] One test pins the pure boundary: the compile-normalize path leaves the process set and event store unchanged, the compile/render applications keep `[kernel, stdlib]` as their complete dependency list, and the invoke compiler/normalizer/renderer sources introduce no atom-creation BIF. Artifact: `soma_service_envelope_tests:test_invoke_compile_normalize_boundary_is_pure` checks spawn traces, process and event snapshots, both application manifests, and the four named production sources.
- Criterion 6 — pass: - [x] `docs/contracts/RS.1a-test-contract.md` maps every acceptance criterion to its proving test. Artifact: `soma_rs1a_contract_doc_tests:test_rs1a_contract_maps_every_criterion_to_proving_case` checks one criterion heading and one full module/function proof name for all six criteria.

Gate roll-up: `rebar3 eunit` passed 415 tests with 0 failures. `rebar3 ct` passed 469 tests with 0 failures.

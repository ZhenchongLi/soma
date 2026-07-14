### Claude

## Verdict

changes-requested

## Real issues

- `soma_lisp` crashes on a canonical envelope accepted by the public compiler and normalizer. `(args (from_step "prior"))` compiles and normalizes to `#{from_step => <<"prior">>}` because `parse_args/2` accepts any reference term and the normalizer only requires an args map. `render_canonical_args/1` then sends that binary to the atom-only `render_canonical_symbol/1` at `apps/soma_event_store/src/soma_lisp.erl:153`, raising `function_clause`. This breaks the required render/compile round trip. The criterion-4 table covers only atom reference ids, so the suite stays green while production crashes.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: - [x] A valid tool envelope yields `operation => #{kind => tool, step => #{id => RequestId, tool => Tool, args => Args}}` through `soma_lfe:compile/2` → `soma_service_envelope:normalize/1`, with every declared field preserved and the normalized map containing only `kind`, `api_version`, `request_id`, `operation`, `scope`, `deadline_ms`, `max_output_bytes`, `correlation_id`, `artifacts`. Artifact: `soma_service_envelope_tests:test_valid_tool_invoke_compiles_and_normalizes` asserts the full nine-field map and exact key allowlist; `rebar3 eunit` passed 414 tests.
- Criterion 2 — pass: - [x] A valid steps envelope yields `operation => #{kind => steps, steps => Steps}` with the source-ordered canonical list, byte-identical to what the existing `(run-steps ...)` step production emits for the same step forms (one shared `parse_proposal_steps/1` production; one test). Artifact: `soma_service_envelope_tests:test_valid_steps_invoke_matches_run_steps_production` compares `term_to_binary/1` output and pins both parser branches to `parse_proposal_steps/1`.
- Criterion 3 — pass: - [x] One table-driven test proves each invalid envelope class returns its distinct bounded typed error — `missing_api_version`, `unsupported_api_version` (anything but binary `<<"1">>`), `missing_request_id`, `invalid_request_id`, `duplicate_field` (rejected at the compiler boundary), `unknown_field`, `invalid_operation` (anything but exactly one well-formed tool-or-steps operation), `invalid_budget` (`deadline_ms`/`max_output_bytes` outside positive integers), `scope_entry_too_large` (binary entries above 255 bytes), `invalid_artifacts`, `invalid_correlation_id` — and growing a rejected value to 64 KiB leaves its typed error byte-identical. Artifact: `soma_service_envelope_tests:test_invalid_invoke_classes_return_fixed_typed_errors` enumerates all eleven codes, checks uniqueness and bounded diagnostic keys, and compares each small/64-KiB pair as both terms and binaries.
- Criterion 4 — fail: - [x] Every canonical invoke map survives the `soma_lisp:render/1` → `soma_lfe:compile/2` round trip without data loss. Artifact: compiling and normalizing `(invoke (api-version "1") (request-id "r") (tool (name echo) (args (from_step "prior"))))` succeeds, but `soma_lisp:render/1` raises `function_clause` in `render_canonical_symbol/1` at `apps/soma_event_store/src/soma_lisp.erl:153`. `soma_lisp_invoke_tests:test_canonical_invoke_maps_round_trip_through_render_and_compile` tests only atom reference ids.
- Criterion 5 — pass: - [x] One test pins the pure boundary: the compile-normalize path leaves the process set and event store unchanged, the compile/render applications keep `[kernel, stdlib]` as their complete dependency list, and the invoke compiler/normalizer/renderer sources introduce no atom-creation BIF. Artifact: `soma_service_envelope_tests:test_invoke_compile_normalize_boundary_is_pure` checks spawn traces, process and event snapshots, both application manifests, and all four named sources.
- Criterion 6 — pass: - [x] `docs/contracts/RS.1a-test-contract.md` maps every acceptance criterion to its proving test. Artifact: `soma_rs1a_contract_doc_tests:test_rs1a_contract_maps_every_criterion_to_proving_case` checks one criterion heading and one full module/function proof name for all six criteria.

Full gate: `rebar3 eunit` passed 414 tests with 0 failures; `rebar3 ct` passed 469 tests.

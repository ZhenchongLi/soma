### Claude

## Verdict

changes-requested

## Real issues

- `valid_canonical_args/1` still declares every map without a mixed bare `from_step` canonical at `apps/soma_actor/src/soma_service_envelope.erl:223-226`, but `soma_lisp` only handles atom-keyed, reader-representable argument terms. A raw envelope with `args => #{<<"value">> => <<"x">>}` normalizes to `{ok, _}` and then crashes in `render_canonical_symbol/1`. One with `args => #{value => 1.5}` normalizes, renders, and fails compilation at the decimal point. `normalize/1` is still minting canonical envelopes that cannot round-trip, so criterion 3's `invalid_operation` coverage and criterion 4 both fail. The new regression covers only the mixed bare `from_step` shape.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: - [x] A valid tool envelope yields `operation => #{kind => tool, step => #{id => RequestId, tool => Tool, args => Args}}` through `soma_lfe:compile/2` → `soma_service_envelope:normalize/1`, with every declared field preserved and the normalized map containing only `kind`, `api_version`, `request_id`, `operation`, `scope`, `deadline_ms`, `max_output_bytes`, `correlation_id`, `artifacts`. Artifact: `soma_service_envelope_tests:valid_tool_invoke_compiles_and_normalizes_test` passed and asserts the full nine-field result plus the exact top-level key allowlist.
- Criterion 2 — pass: - [x] A valid steps envelope yields `operation => #{kind => steps, steps => Steps}` with the source-ordered canonical list, byte-identical to what the existing `(run-steps ...)` step production emits for the same step forms (one shared `parse_proposal_steps/1` production; one test). Artifact: `soma_service_envelope_tests:valid_steps_invoke_matches_run_steps_production_test` passed, compares both lists with `term_to_binary/1`, and pins both parser branches to `parse_proposal_steps/1`.
- Criterion 3 — fail: - [x] One table-driven test proves each invalid envelope class returns its distinct bounded typed error — `missing_api_version`, `unsupported_api_version` (anything but binary `<<"1">>`), `missing_request_id`, `invalid_request_id`, `duplicate_field` (rejected at the compiler boundary), `unknown_field`, `invalid_operation` (anything but exactly one well-formed tool-or-steps operation), `invalid_budget` (`deadline_ms`/`max_output_bytes` outside positive integers), `scope_entry_too_large` (binary entries above 255 bytes), `invalid_artifacts`, `invalid_correlation_id` — and growing a rejected value to 64 KiB leaves its typed error byte-identical. Artifact: a direct production call with `args => #{value => 1.5}` returns `{ok, _}` from `soma_service_envelope:normalize/1` instead of the fixed `invalid_operation` error; the table omits non-reader-representable raw argument terms.
- Criterion 4 — fail: - [x] Every canonical invoke map survives the `soma_lisp:render/1` → `soma_lfe:compile/2` round trip without data loss. Artifact: a direct production call accepts `args => #{<<"value">> => <<"x">>}` as canonical, then `soma_lisp:render/1` raises `function_clause` in `render_canonical_symbol/1` instead of producing a compilable round-trip form.
- Criterion 5 — pass: - [x] One test pins the pure boundary: the compile-normalize path leaves the process set and event store unchanged, the compile/render applications keep `[kernel, stdlib]` as their complete dependency list, and the invoke compiler/normalizer/renderer sources introduce no atom-creation BIF. Artifact: `soma_service_envelope_tests:invoke_compile_normalize_boundary_is_pure_test` passed and checks spawn traces, process and event snapshots, both application manifests, and all four named production sources.
- Criterion 6 — pass: - [x] `docs/contracts/RS.1a-test-contract.md` maps every acceptance criterion to its proving test. Artifact: `soma_rs1a_contract_doc_tests:rs1a_contract_maps_every_criterion_to_proving_case_test` passed and checks one criterion heading plus one full module/function proof name for all six criteria.

Gate roll-up: the three RS.1a proof modules passed all 9 focused tests. `rebar3 eunit` passed 417 tests with 0 failures. `rebar3 ct` passed 469 tests with 0 failures.

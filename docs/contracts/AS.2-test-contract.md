# AS.2 Test Contract — `(explore ...)` edge form

This document maps every behavioural guarantee of the AS.2 explore-form slice
(issue #230) to the test that proves it. The form is a compile-only edge:
`soma_lfe:compile/2` lowers constrained `(explore ...)` source to canonical
step data, while `soma_lisp:render/1` provides the reversible term-to-Lisp
direction. Neither path adds runtime execution, actor, policy, or budget
semantics.

## Criterion 1 — canonical, ordered, compile-only explore data

| Guarantee | Proof |
| --- | --- |
| Valid explore steps compile in source order to `#{kind => explore, steps => Steps}`, with canonical arguments, optional `timeout_ms`, and output matching the shared `(run-steps ...)` step shape. | `soma_lfe_explore_tests:test_explore_compiles_canonical_steps_and_matches_run_steps` |
| Compiling a valid explore form starts no child process or runtime/actor supervisor and emits no event. | `soma_lfe_explore_tests:test_explore_compile_starts_no_processes_or_events` |
| Explore and `(run-steps ...)` both use the single `parse_proposal_steps/1` production. | `soma_lfe_explore_tests:test_explore_and_run_steps_share_proposal_step_production` |
| The compile-only dependency boundary remains `kernel`/`stdlib`, touched compiler boundaries import no runtime layer, and touched compiler/renderer boundaries add no atom-creation BIF. | `soma_lfe_explore_tests:test_explore_source_keeps_dependency_and_atom_creation_boundaries` |

## Criterion 2 — distinct, fixed explore diagnostics

| Guarantee | Proof |
| --- | --- |
| Empty `(explore)` returns the fixed `empty_explore` diagnostic. | `soma_lfe_explore_tests:test_empty_explore_returns_fixed_diagnostic` |
| A malformed explore step returns one fixed `invalid_explore_step` diagnostic whose content is unchanged by a large rejected value. | `soma_lfe_explore_tests:test_malformed_explore_step_returns_fixed_diagnostic` |
| An unknown explore-level child returns one fixed `unknown_explore_form` diagnostic whose content is unchanged by a large rejected value, and all three explore diagnostic codes remain distinct. | `soma_lfe_explore_tests:test_unknown_explore_level_form_returns_fixed_diagnostic` |

## Criterion 3 — canonical explore maps round-trip as `(explore ...)`

| Guarantee | Proof |
| --- | --- |
| Canonical explore maps render with an `(explore ...)` head and compile back to the identical map, preserving step order, empty arguments, `timeout_ms`, both `from_step` shapes, and underscore-bearing ids, tools, keys, and atom values. | `soma_lisp_explore_tests:test_canonical_explore_maps_round_trip_through_render_and_compile` |

## Criterion 4 — this contract maps every guarantee to its proof

| Guarantee | Proof |
| --- | --- |
| The AS.2 contract names every acceptance proof by its full module and test name. | `soma_as2_contract_doc_tests:test_as2_contract_names_every_acceptance_proof` |

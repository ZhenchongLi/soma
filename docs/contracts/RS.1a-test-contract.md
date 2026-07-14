# RS.1a Test Contract — invoke envelope form and pure normalization

This document maps every acceptance criterion of the RS.1a service-envelope
slice (issue #243) to the test case that proves it. RS.1a ends at compilation,
normalization, and rendering; it does not add service ingress or execution.

## Criterion 1 — a tool envelope compiles and normalizes to the allowlisted map

| Guarantee | Proof |
| --- | --- |
| The locked tool invoke form compiles through the public Lisp edge and normalizes to the exact canonical envelope. | `soma_service_envelope_tests:test_valid_tool_invoke_compiles_and_normalizes` |

## Criterion 2 — a steps envelope reuses the run-steps production and preserves order

| Guarantee | Proof |
| --- | --- |
| Invoke steps use the existing run-steps parser production and preserve the canonical step list in source order. | `soma_service_envelope_tests:test_valid_steps_invoke_matches_run_steps_production` |

## Criterion 3 — every invalid class has a distinct fixed bounded error

| Guarantee | Proof |
| --- | --- |
| Compiler and normalizer rejections use the eleven distinct fixed diagnostics without embedding rejected data. | `soma_service_envelope_tests:test_invalid_invoke_classes_return_fixed_typed_errors` |

## Criterion 4 — every canonical invoke shape survives render and compile

| Guarantee | Proof |
| --- | --- |
| Canonical tool and steps envelopes round-trip through Lisp rendering and compilation without changing the map. | `soma_lisp_invoke_tests:test_canonical_invoke_maps_round_trip_through_render_and_compile` |

## Criterion 5 — compile and normalization remain pure boundaries

| Guarantee | Proof |
| --- | --- |
| Invoke compilation and normalization create no process or event side effects and retain the locked dependency and atom-creation boundaries. | `soma_service_envelope_tests:test_invoke_compile_normalize_boundary_is_pure` |

## Criterion 6 — this contract names every proving test

| Guarantee | Proof |
| --- | --- |
| This document names one proving module and case for each acceptance criterion of issue #243. | `soma_rs1a_contract_doc_tests:test_rs1a_contract_maps_every_criterion_to_proving_case` |

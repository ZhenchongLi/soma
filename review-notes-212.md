### Claude

## Verdict

Approve. The branch does the narrow thing #212 asked for: planning prompts read the live tool catalog at prompt-build time, render only model-facing catalog fields, preserve the existing `(run-steps ...)` planning path, and leave the policy/budget execution gate intact.

## Real issues

None found.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] With a concrete `allowed_tools` list, the planning system prompt renders each allowed tool that has a catalog entry as a Lisp forms block carrying its name, description, and declared params; contains no tool outside the allowlist; still names an allowed tool without a catalog entry in the plain tool-name list; and keeps the `(run-steps ...)` answer directive.

  Evidence artifact: `planning_prompt_renders_allowed_catalog_entries_test_` passed under `rebar3 eunit --module=soma_actor_call_opts_tests` (`11 tests, 0 failures`). The test registers a described tool and a description-less allowed tool, checks the allowed described tool's `(tool ...)` block includes name/description/param data, checks `file_write` is absent, checks the bare allowed tool name remains in the plain list, and checks `(run-steps ...)` remains present.

- [x] With an `all` policy, the prompt renders every catalog entry and keeps the `(run-steps ...)` directive.

  Evidence artifact: `planning_prompt_all_policy_renders_full_catalog_test_` passed under `rebar3 eunit --module=soma_actor_call_opts_tests` (`11 tests, 0 failures`). The test reads `soma_tool_registry:catalog/0`, asserts the seeded catalog names, then verifies every catalog entry name and description appears in the all-policy planning prompt along with `(run-steps ...)`.

- [x] A tool registered through `soma_tool_registry:register_tool/1` with a description appears in the next planning prompt built after registration -- no code change, no actor restart (a fresh catalog read per prompt build).

  Evidence artifact: `registered_tool_appears_in_next_planning_prompt_test_` passed under `rebar3 eunit --module=soma_actor_call_opts_tests` (`11 tests, 0 failures`). The test builds once before registration, registers `late_registered_tool`, then builds again with the same model config and sees the new tool name and description immediately.

- [x] The rendered prompt carries none of the runtime-internal descriptor fields (`module`, `executable`, `argv`, `effect`, `idempotent`, `timeout_ms`) -- rendering reads `catalog/0` entries, never raw descriptors -- and the existing planning gate contract holds: fixed responses, no model socket, reply text still flows content -> `(run-steps ...)` -> `soma_lfe:compile/2` -> normalize -> policy -> budget.

  Evidence artifact: `planning_prompt_carries_no_runtime_descriptor_fields_test_` passed under `rebar3 eunit --module=soma_actor_call_opts_tests` (`11 tests, 0 failures`), registering a described CLI tool with distinctive executable/argv/runtime fields and verifying those internals do not appear. The unchanged planning-gate CT artifact also passed: `rebar3 ct --suite apps/soma_actor/test/soma_actor_real_provider_SUITE` (`All 8 tests passed`), covering fixed response seams, no model socket, planning content compilation through `soma_lfe:compile/2`, normalization, policy, and budget flow.

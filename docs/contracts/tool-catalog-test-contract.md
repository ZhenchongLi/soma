# Tool Catalog Test Contract

This contract covers manifest v2 — the optional model-facing half of the tool
manifest (`description` + `params`) and the registry catalog that exposes it
(T.1 in `docs/tool-abstraction.md`; issue #203). The fields are additive: a
manifest without them normalizes exactly as before, and the catalog never
leaks runtime-facing fields.

## Manifest Contract

The normalize behavior is proved by `soma_tool_manifest_tests`:

| Behavior | Proof |
| --- | --- |
| `normalize/1` preserves a valid optional `description` (binary) and `params` list in the descriptor. | `normalize_accepts_description_and_params_test` |
| A non-binary `description` is rejected with `{error, {invalid_description, Value}}`. | `normalize_rejects_invalid_model_facing_fields_test` |
| A malformed `params` value — non-list, improper list tail, non-map spec, spec missing `name`/`type`/`required`, `type` outside `string \| integer \| boolean`, non-binary `doc` — is rejected with `{error, {invalid_params, Offending}}`. | `normalize_rejects_invalid_model_facing_fields_test` |
| A manifest without `description`/`params` normalizes to exactly the v1 descriptor — no new keys. | `normalize_without_model_facing_fields_adds_no_keys_test` |

## Catalog Contract

The catalog behavior is proved by `soma_tool_registry_tests`:

| Behavior | Proof |
| --- | --- |
| Each catalog entry is exactly `#{name, description, params}`, `params` defaulting to `[]`; runtime-facing fields (`module`, `executable`, `argv`, `effect`, `idempotent`, `timeout_ms`) never appear. | `catalog_entry_is_exactly_name_description_params_test_` |
| A registered tool without a `description` stays resolvable but is absent from `catalog/0`. | `tool_without_description_absent_from_catalog_test_` |
| A manifest with model-facing fields registered through `register_tool/1` appears in `catalog/0` with those fields verbatim. | `register_tool_with_model_facing_fields_appears_in_catalog_test_` |
| A freshly seeded registry catalogs all five built-ins, each with a non-empty binary description. | `seeded_catalog_lists_all_five_builtins_test_` |

## Planning-Prompt Contract

The planning prompt's consumption of the catalog (issue #212) is proved by
`soma_actor_call_opts_tests` (eunit, registry fixture) and, for the unchanged
planning gate, the existing `soma_actor_real_provider_SUITE` CT cases:

| Behavior | Proof |
| --- | --- |
| With a concrete allowlist, each allowed tool with a catalog entry renders as a Lisp `(tool ...)` block carrying its registry-spelled name, description, and declared params; an off-allowlist catalog entry leaves no trace; an allowed tool without a catalog entry stays in the plain name list; the `(run-steps ...)` directive is kept. | `planning_prompt_renders_allowed_catalog_entries_test_` |
| With an `all` policy, every catalog entry's name and description render, and the `(run-steps ...)` directive is kept. | `planning_prompt_all_policy_renders_full_catalog_test_` |
| A tool registered through `register_tool/1` after actor start appears in the next planning prompt built with the same config — the builder reads `catalog/0` fresh on every planning build. | `registered_tool_appears_in_next_planning_prompt_test_` |
| The rendered prompt carries none of the runtime descriptor fields — not a `cli` tool's `executable` path or `argv` values, not a built-in's module name, not `effect` / `idempotent` / `timeout_ms` field text. Rendering reads `catalog/0` entries, never raw descriptors. | `planning_prompt_carries_no_runtime_descriptor_fields_test_` |
| The planning gate contract holds unchanged: fixed `response` seam, no model socket, content → `(run-steps ...)` → `soma_lfe:compile/2` → normalize → policy → budget. | `planning_mode_real_response_runs_plan_to_completion`, `planning_mode_malformed_plan_fails_task_actor_alive`, `planning_mode_off_yields_reply_proposal_unchanged`, `planning_mode_api_key_appears_in_no_emitted_event` (unmodified, in `soma_actor_real_provider_SUITE`) |

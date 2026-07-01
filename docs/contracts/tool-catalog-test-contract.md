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

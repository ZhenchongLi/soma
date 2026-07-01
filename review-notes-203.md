# Review notes — #203 Manifest v2: model-facing description/params and registry catalog

### Claude

## Verdict
changes-requested

## Real issues

1. **The contract docs were skipped.** `docs/tool-manifest.md` is the normative
   manifest contract and contains zero mention of `description` or `params` —
   an external manifest author reading it cannot discover the model-facing
   fields, and `{invalid_description, _}` / `{invalid_params, _}` are
   rejections the contract never names. CLAUDE.md requires each new behavioural
   guarantee to land in the relevant `docs/contracts/` file, and
   `design-203.md` (Approach, last two paragraphs) committed to both updates.
   Neither file is in the diff. Consequence: the contract doc lies by omission
   from the first merge, and the next manifest change compounds the drift.
   Add the optional-fields section to `docs/tool-manifest.md` and the catalog
   guarantees to a contracts file.

## Questions

1. An improper `params` list (`[GoodSpec | garbage]`) passes the `is_list/1`
   guard (it only checks the head cons cell), then `check_param_specs/1` hits
   no clause on the tail → `function_clause` inside the registry `gen_server`
   → restart drops every dynamically registered tool. The pre-existing
   `executable => 42` path crashes the same way
   (`has_internal_whitespace/1` has no integer clause), so this matches the
   module's established granularity — flagging it, not blocking on it.
   Deliberate?

## Nits

1. `valid_param_spec(#{...} = Spec) when is_map(Spec)` — the guard is
   redundant; the map pattern already implies it.
   `apps/soma_tools/src/soma_tool_manifest.erl:103`.
2. `check_adapter_fields/1`'s final catch-all clause is unreachable:
   `check_adapter/1` already restricts `adapter` to `erlang_module | cli`, and
   both have matching clauses above. Pre-existing shape, carried forward.

## Functional evidence

- Criterion 1 — pass: `normalize_accepts_description_and_params_test`
  (`apps/soma_tools/test/soma_tool_manifest_tests.erl`) — normalizes a manifest
  with a binary description plus three param specs (string/integer/boolean, one
  with `doc`), asserts `maps:get(description, Normalized)` and
  `maps:get(params, Normalized)` equal the input verbatim.
- Criterion 2 — pass: `normalize_rejects_invalid_model_facing_fields_test` —
  three non-binary descriptions each yield
  `{error, {invalid_description, Value}}`; three non-list `params` values and
  six bad specs (non-map, missing `name`/`type`/`required`, `type => float`,
  string `doc`) each yield `{error, {invalid_params, Value}}` carrying the
  offending value.
- Criterion 3 — pass: `normalize_without_model_facing_fields_adds_no_keys_test`
  — exact-map equality `{ok, Manifest}` for both an `erlang_module` and a `cli`
  v1 manifest, plus `maps:is_key` false for `description`/`params`. Existing
  tests untouched (both test-file diffs are pure additions); full gate green:
  EUnit 358/0, CT 357/0.
- Criterion 4 — pass:
  `catalog_entry_is_exactly_name_description_params_test_`
  (`apps/soma_tools/test/soma_tool_registry_tests.erl`) — every catalog entry's
  sorted key set asserted equal to `[description, name, params]`, all six
  forbidden keys asserted absent per entry, and the params-less entry equals
  `#{name => catalog_minimal_tool, description => ..., params => []}`.
- Criterion 5 — pass: `tool_without_description_absent_from_catalog_test_` — a
  v1 manifest registers, `resolve_descriptor(v1_only_tool)` matches
  `{ok, #{name := v1_only_tool}}`, and the catalog comprehension for that name
  returns `[]`.
- Criterion 6 — pass:
  `register_tool_with_model_facing_fields_appears_in_catalog_test_` — a
  manifest with description + two param specs goes through the live
  `register_tool/1` `gen_server` path; the single catalog entry equals
  `#{name, description, params}` with the registered values verbatim.
- Criterion 7 — pass: `seeded_catalog_lists_all_five_builtins_test_` — a fresh
  `start_link/0` (the same `init`/`seed` the supervisor runs) yields catalog
  names exactly `[echo, fail, file_read, file_write, sleep]`, each entry a
  non-empty binary description.

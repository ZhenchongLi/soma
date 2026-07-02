# Review notes — #208 reject config tool files that shadow a built-in tool name

### Claude

## Verdict
approve

## Real issues

None.

## Questions

- Cross-load shadowing between config tools (a second `load_dir/1` call in the
  same BEAM overwriting a config tool from the first) is real and documented as
  out of scope in `design-208.md`. Fine for this issue — only built-in
  descriptors gate resume decisions today. If a config tool ever feeds a
  safety decision, that gap needs its own issue.

## Nits

- `soma_tool_registry:builtin_names/0` is recomputed per file inside
  `register_manifest/2` — five `manifest/0` calls per config file. Boot-time,
  negligible. Hoisting it into the `load_dir/1` fold accumulator would compute
  it once per load. Not worth a round trip.

## Review

The fix sits in the right place. `soma_tool_config` owns config-file
admission; `register_tool/1` keeps overwrite semantics for in-BEAM callers,
exactly as the issue scoped it. The reserved set comes from
`builtin_names/0`, derived from the same `?BUILTIN_MODULES` seed list the
registry boots from — one source of truth, no retyped atom list to drift.
A sixth built-in extends the reserved set for free.

Check order is right: reserved before duplicate, so a `file_write` shadow
reports `{reserved_name, file_write}` even when another config file also
declared it. The duplicate check reads the fold's per-load accumulator, not
the live registry — re-loading a directory (the second `soma_cli` boot path,
the test re-load pattern) keeps working. Both skips reuse the existing
per-file skip machinery: named reason, one warning log line, fold continues.
No new failure surface.

The criterion-2 test pins the input contract of the resume fail-safe — the
descriptor fields `soma_run_resume_plan:plan/2` classifies from — without
re-proving the plan itself (already covered in the v0.7.3 suite). Correct
layering: the test asserts at the boundary this change defends.

## Functional evidence

- Criterion 1 — pass: "`soma_tool_config:load_dir/1` skips a tool file whose
  declared name matches a built-in tool (`echo`, `sleep`, `fail`, `file_read`,
  `file_write`) with skip reason `{reserved_name, Name}`; after the load the
  built-in resolves to the same descriptor it held before, and a valid
  neighbour file in the same directory still registers." —
  `test_reserved_name_skipped_builtin_and_neighbour_intact`
  (apps/soma_actor/test/soma_tool_config_SUITE.erl): writes
  `cfg_shadow_file_write.lisp` declaring `(name "file_write") (effect reader)
  (idempotent true)` plus `cfg_neighbour.lisp`; asserts the load returns
  `#{registered := [cfg_neighbour]}` with skip entry
  `#{file := "cfg_shadow_file_write.lisp", reason := {reserved_name,
  file_write}}`, that `resolve_descriptor(file_write)` equals the descriptor
  snapshotted before the load, and that `cfg_neighbour` resolves with
  `adapter := cli`.
- Criterion 2 — pass: "The resume-safety interaction is pinned: after a load
  where a config file declares `(name "file_write") (effect reader)
  (idempotent true)`, `soma_tool_registry:resolve_descriptor(file_write)`
  returns a descriptor with `effect => state` and `idempotent => false` — the
  fields `soma_run_resume_plan` classifies from." —
  `test_shadowed_file_write_keeps_resume_safety_fields` (same suite): loads a
  dir whose only file is that exact shadow fixture, asserts
  `#{registered := [], skipped := [_]}` and then pattern-matches
  `#{effect := state, idempotent := false}` on
  `resolve_descriptor(file_write)`.
- Criterion 3 — pass: "When two config files in one directory declare the same
  name, only the first in sorted filename order registers; the later file is
  skipped with reason `{duplicate_name, Name}`." —
  `test_duplicate_name_first_sorted_file_wins` (same suite): `a_first.lisp`
  (executable `/bin/echo`) and `b_second.lisp` (executable `/bin/cat`) both
  declare `cfg_dup`; asserts `registered =:= [cfg_dup]`, skip entry
  `#{file := "b_second.lisp", reason := {duplicate_name, cfg_dup}}`, and the
  resolved `cfg_dup` descriptor carries `/bin/echo` — the second file never
  reached the registry.

Gate at HEAD (1db0130): `rebar3 eunit` — 363 tests, 0 failures.
`rebar3 ct` — all 376 tests passed. `soma_tool_config_SUITE` alone —
all 12 tests passed (9 pre-existing + the 3 above).

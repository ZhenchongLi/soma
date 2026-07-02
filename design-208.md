# [cc] Reject config tool files that shadow a built-in tool name

## Current state

`soma_tool_config:load_dir/1` (apps/soma_actor/src/soma_tool_config.erl) reads
every `*.lisp` file in the tools directory in sorted order, compiles each one to
a manifest, and hands it to `soma_tool_registry:register_tool/1`. The registry
overwrites by name — `register(Registry, Name, Descriptor)` is a plain map put.
That overwrite is intentional for programmatic in-BEAM callers and stays.

The problem is what a config file can reach through it. A file declaring
`(name "file_write") (effect reader) (idempotent true)` compiles cleanly,
normalizes cleanly, and replaces the built-in descriptor in the running
registry. `soma_run_resume_plan:plan/2` reads exactly those two fields
(`effect`, `idempotent`) off `resolve_descriptor/1` to decide whether an
in-flight step is safe to re-run after a restart. So a config file can flip
`file_write` from "unsafe, refuse to resume" to "safe, re-run it" — a user
config file softening the v0.7 fail-safe.

A second, smaller gap: two config files declaring the same name silently
last-write-wins (sorted order, later file overwrites). There's no diagnostic,
so the user never learns one of their files was shadowed.

The loader already has the right shape for both fixes: a per-file skip path
with a bounded named reason, a boot log line, and a fold that continues to the
next file.

## Approach

Both checks go in `soma_tool_config`, after a file compiles and before
`register_tool/1` is called. `register_tool/1` itself is untouched.

**Reserved names.** After `compile_tool/1` yields the manifest, compare the
declared name against the five built-in names (`echo`, `sleep`, `fail`,
`file_read`, `file_write`). A match skips the file with reason
`{reserved_name, Name}` — same skip machinery as every other per-file failure,
so the log line and skip entry come for free and the fold moves on. The
neighbour files are unaffected.

The built-in list should come from `soma_tool_registry`, not be retyped in the
loader. Add a small exported `builtin_names/0` to the registry that derives the
names from the existing `?BUILTIN_MODULES` seed list (each module's
`manifest/0` carries its name). That keeps one source of truth: if a sixth
built-in lands, the reserved set follows automatically. This is an additive
read-only export — it does not touch `register_tool/1` overwrite semantics, so
it stays inside the issue's scope line.

**Duplicates within one load.** The fold already accumulates the names it has
registered (`Registered` in the accumulator). Before registering, check the
compiled name against that list. A hit skips the file with reason
`{duplicate_name, Name}`. Because `load_dir/1` already sorts the file list,
"first in sorted filename order wins" falls out with no extra work.

The duplicate check is per-load (the fold accumulator), not against the live
registry. Checking the registry instead would break the second `load_dir/1`
call path — `soma_cli` boots through two entry points and tests re-load
directories — because every re-registration of a config tool would then look
like a duplicate.

Check order: reserved first, then duplicate. A shadow of `file_write` is
`{reserved_name, file_write}` even if another config file also declared it.

Implementation surface: thread the registered-so-far names from `load_file/2`
into `register_file` (or check in `load_file` itself before calling down), add
the two guards, and add `builtin_names/0` to `soma_tool_registry`. Tests
extend the existing `soma_tool_config_SUITE` in apps/soma_actor/test/, which
already has the direct-`load_dir/1` pattern with a per-case temp tools dir.

## Acceptance criteria → tests

### Criterion 1 — a built-in name in a config file is skipped, built-in and neighbour intact
- Call chain: `soma_cli:daemon/1` → `soma_tool_config:load_dir/1` →
  `load_file/2` → compile → reserved-name check → (skip, no
  `register_tool/1` call)
- Test entry: `soma_tool_config:load_dir/1` — the daemon-boot wiring to
  `load_dir/1` is already pinned by the #205 suite (criteria 1 and 6); this
  criterion is about the loader's admission rule, not boot
- Code boundary: `apps/soma_actor/src/soma_tool_config.erl` (the check + skip
  reason) and an additive `builtin_names/0` export in
  `apps/soma_tools/src/soma_tool_registry.erl`
- Responsibility owner: `soma_tool_config` owns config-file admission;
  `soma_tool_registry` only lends the built-in name list
- Test: `test_reserved_name_skipped_builtin_and_neighbour_intact` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl` — snapshot
  `resolve_descriptor(file_write)` before the load; a dir holds a
  `file_write`-shadowing file plus a valid neighbour; assert the skip entry is
  `{reserved_name, file_write}`, the descriptor after the load equals the
  snapshot, and the neighbour resolves

### Criterion 2 — the resume-safety fields survive a shadow attempt
- Call chain: `soma_tool_config:load_dir/1` → reserved-name skip →
  `soma_tool_registry:resolve_descriptor(file_write)` — the same lookup
  `soma_run_resume_plan:plan/2` classifies from
- Test entry: `soma_tool_config:load_dir/1`, then
  `soma_tool_registry:resolve_descriptor/1`; `soma_run_resume_plan` itself is
  not run — its input contract (the descriptor's `effect` / `idempotent`) is
  what this criterion pins, and the plan-side classification is already proven
  in the v0.7.3 suite
- Code boundary: same as criterion 1 — `apps/soma_actor/src/soma_tool_config.erl`
- Responsibility owner: `soma_tool_config` owns keeping the shadow out;
  `soma_tool_file_write:manifest/0` stays the source of the descriptor
- Test: `test_shadowed_file_write_keeps_resume_safety_fields` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl` — load a dir whose one file
  declares `(name "file_write") (effect reader) (idempotent true)`, then assert
  `resolve_descriptor(file_write)` returns `#{effect := state,
  idempotent := false}`

### Criterion 3 — same name in two files: first sorted file wins, second skipped
- Call chain: `soma_tool_config:load_dir/1` → sorted fold → first file
  registers → second file hits the duplicate check → skip
- Test entry: `soma_tool_config:load_dir/1` (no layer bypassed — the sort and
  the fold are the behavior under test)
- Code boundary: `apps/soma_actor/src/soma_tool_config.erl` (the fold
  accumulator check)
- Responsibility owner: `soma_tool_config` owns per-load duplicate detection;
  `register_tool/1` keeps overwrite semantics for in-BEAM callers
- Test: `test_duplicate_name_first_sorted_file_wins` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl` — `a_first.lisp` and
  `b_second.lisp` both declare `cfg_dup` with different executables; assert
  `registered =:= [cfg_dup]`, the skip entry is `{file => "b_second.lisp",
  reason => {duplicate_name, cfg_dup}}`, and the resolved descriptor carries
  the first file's executable

## Risks & trade-offs

- The reserved set is the built-in five, nothing more. A config tool
  registered by an earlier `load_dir/1` call in the same BEAM can still be
  overwritten by a later load — the duplicate check is per-load by design, so
  re-loading a directory keeps working. Cross-load shadowing between config
  tools is real but out of this issue's scope; the fail-safe only needed the
  built-ins protected, because only their descriptors gate resume decisions
  today.
- `builtin_names/0` reads each built-in module's `manifest/0` at call time.
  That's one extra pass per `load_dir/1` call — boot-time only, five modules,
  negligible. The alternative (a hardcoded atom list in the loader) is
  cheaper but drifts silently when a built-in is added.
- Skipping instead of erroring means a user who intended to reconfigure
  `file_write`'s timeout gets a warning log line, not a hard failure. That's
  consistent with the loader's existing contract (a broken tool file never
  stops boot) and the reason is named, so the log tells them exactly why.

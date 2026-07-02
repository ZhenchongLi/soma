# Review notes — #205 Config-registered cli tools from ~/.soma/tools at daemon boot

### Claude

## Verdict
changes-requested

## Real issues

1. **A tool file with non-ASCII text crashes daemon boot instead of being
   skipped.** `soma_tool_config:load_file/2`
   (`apps/soma_actor/src/soma_tool_config.erl:52`) has no isolation around
   `soma_lfe_reader:read_forms/1`, and the reader crashes on two input
   classes user files will hit:
   - invalid UTF-8 bytes (a Latin-1-saved file):
     `unicode:characters_to_list/1` returns an error tuple that
     `scan/3` doesn't match — `function_clause` at
     `apps/soma_lfe/src/soma_lfe_reader.erl:28`;
   - valid UTF-8 with any code point > 255 (an em-dash, an accent, a
     Chinese character): `list_to_binary/1` badarg at
     `apps/soma_lfe/src/soma_lfe_reader.erl:73`.

   Reproduced against the branch build:
   `(description "Résumé formatter — uppercase")` kills
   `soma_cli:daemon/1` with the badarg above, and a `\xff\xfe` byte pair
   kills it with the function_clause. In both runs the valid neighbor file
   in the same directory never registered — one bad file takes down the
   whole loader and the daemon with it. Criterion 6 promises
   skip-with-named-diagnostic-and-serve for exactly this class ("a file
   that fails to parse ... is skipped ... the daemon serves requests");
   the suite only exercises the failure modes the reader reports
   politely. Fix the reader's unicode handling
   (`unicode:characters_to_binary` at line 73, handle the
   `characters_to_list` error return at line 18) or isolate per-file
   failure in the loader — either way, add the non-ASCII case to
   `soma_tool_config_SUITE`.

## Questions

1. Built-in shadowing has sharper teeth than the design's risk note says.
   `register_tool/1` overwrites by name, so a config file declaring
   `(name "file_write") (effect reader) (idempotent true)` replaces the
   built-in descriptor — and `soma_run_resume_plan` classifies an
   in-flight step's resume safety from that descriptor's
   `effect`/`idempotent`. The shadowed descriptor makes the resume
   executor re-run a real write it would otherwise refuse. Trusted local
   config, deferred by design, criteria locked — fine for this slice, but
   the follow-up reserved-name check should cite the resume-safety
   interaction, not just name collision.
2. `daemon_foreground/1` gets the same three loader lines as `daemon/1`
   but no test enters through it. The code is symmetric today; nothing
   pins it.

## Nits

- `resolve_tools_dir/1` with `HOME` unset falls back to `"/.soma/tools"`
  (`apps/soma_actor/src/soma_cli.erl`) — a path under the filesystem
  root. Harmless because the wildcard on a missing dir returns `[]`, but
  it reads like a real default when it's a dead one.
- The suite's log capture matches the loader's exact format string
  (`soma_tool_config_SUITE.erl:386`). Reword the log line and the capture
  stops matching; the case then fails on the receive timeout, so it's
  caught, but the coupling is brittle.
- `registered_names/0` peeks gen_server state with `sys:get_state`
  (`soma_tool_config_SUITE.erl:372`). A public `names/0` on the process
  API would drop the state peeking.

## Functional evidence

- Criterion 1 — pass: `test_daemon_boot_registers_config_tool`
  (`apps/soma_actor/test/soma_tool_config_SUITE.erl`) boots through
  `soma_cli:daemon/1` with a temp `tools_dir` holding `cfg_upper.lisp`,
  then asserts `soma_tool_registry:resolve_descriptor(cfg_upper)` returns
  `#{adapter := cli}` with executable `/bin/echo` and argv
  `["hello", "world"]` — the declared values, in the running registry.
- Criterion 2 — pass: `test_config_tool_description_in_catalog` writes
  `(description "Uppercase the final argv argument.")`, loads through
  `soma_tool_config:load_dir/1`, and pattern-matches that exact binary
  out of the `cfg_described` entry in `soma_tool_registry:catalog/0`.
- Criterion 3 — pass: `test_invalid_field_surfaces_normalize_error` —
  a file declaring `(effect banana)` skips with reason exactly
  `{invalid_effect, banana}`, the error name
  `soma_tool_manifest:normalize/1` itself produces
  (`apps/soma_tools/src/soma_tool_manifest.erl:26`); the loader
  passes the value through untouched
  (`soma_tool_config.erl:136-137`), so the built-ins' validator is the
  one that judged it.
- Criterion 4 — pass: `test_safety_defaults_and_declared_values` —
  `cfg_defaulted.lisp` (none of the three fields) resolves to
  `#{effect := state, idempotent := false, timeout_ms := 30000}`;
  `cfg_declared.lisp` resolves to
  `#{effect := reader, idempotent := true, timeout_ms := 5000}`. The
  defaults live in one place (`soma_tool_config.erl:30-32`).
- Criterion 5 — pass: `test_non_cli_adapter_rejected` — a file declaring
  `(adapter erlang_module)` skips with
  `{adapter_not_allowed, erlang_module}` at compile stage
  (`soma_tool_config.erl:175-176`, in front of normalize, so a declared
  `module` field can never ride through), and
  `resolve_descriptor(cfg_module_inject)` returns `{error, not_found}`.
- Criterion 6 — fail: `test_broken_file_skipped_daemon_serves` proves the
  polite failure modes (unparseable form → `{parse_error, [...]}`,
  `(effect banana)` → `{invalid_effect, banana}`, survivor registers,
  `soma_cli:ping/1` answers 0) — but a reproduced probe shows the
  guarantee does not hold for the whole "fails to parse" class: a tool
  file containing invalid UTF-8 bytes or any non-ASCII character (em-dash
  in a `description`) crashes `soma_lfe_reader:read_forms/1`
  (function_clause at `soma_lfe_reader.erl:28`, badarg at `:73`),
  the crash propagates through `load_dir/1` uncaught, `soma_cli:daemon/1`
  exits, and the valid neighbor file never registers. See Real issue 1.
- Criterion 7 — pass: `test_missing_or_empty_dir_boot_unchanged` — boot
  with a nonexistent `tools_dir` leaves the registry holding exactly
  `[echo, fail, file_read, file_write, sleep]`; `load_dir/1` on the
  missing path and on an empty dir both return
  `#{registered => [], skipped => []}`; the logger capture receives no
  skip line; the daemon answers ping.
- Criterion 8 — pass: `test_config_tool_runs_end_to_end` — a tool file
  pointing at a real uppercase helper script registers through
  `load_dir/1`, a run enters at `soma_agent_session:start_run/2`, the
  event trail is exactly `run.accepted, run.started, step.started,
  tool.started, tool.succeeded, step.succeeded, run.completed`, and the
  `step.succeeded` output contains `HELLO` — the helper's transform of
  the step input, so the external program really ran through the
  unchanged cli adapter.

Gate roll-up on the branch: `rebar3 eunit` — 360 tests, 0 failures;
`rebar3 ct` — all 372 tests passed.

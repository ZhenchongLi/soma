# [cc] Config-registered cli tools from ~/.soma/tools at daemon boot

## Current state

The registry (`apps/soma_tools/src/soma_tool_registry.erl`) seeds the five
built-ins at start by normalizing each module's `manifest/0` through
`soma_tool_manifest:normalize/1`. It also exposes `register_tool/1`, which
runs the same normalize before storing a descriptor — but nothing calls it at
boot. Manifest v2 (#203) is merged: descriptors may carry `description` /
`params`, and `catalog/0` returns the model-facing halves.

Daemon boot lives in `apps/soma_actor/src/soma_cli.erl`. Both `daemon/1` and
`daemon_foreground/1` load `~/.soma/config` through `soma_config:load/1`
(with a `config_path` test seam), start `soma_runtime`, and start the socket
listener. No step reads a tools directory.

The Lisp reader already exists: `soma_lfe_reader:read_forms/1` (in
`apps/soma_lfe`) parses atoms, strings, integers, and nested lists into plain
Erlang terms, with line-numbered diagnostics. `soma_actor` already depends on
`soma_lfe`, and on `soma_tools` through `soma_runtime`.

So today the only way to wrap an external binary as a soma tool is to write
an Erlang module or call `register_tool/1` from a shell. The tier-2 recipe in
`docs/tool-abstraction.md` §5 — drop a `(tool …)` file in `~/.soma/tools/`
and restart the daemon — has no implementation.

## Approach

One new module, `soma_tool_config`, in `apps/soma_actor/src/` — next to
`soma_config`, because that is where daemon boot lives and the app already
has every dependency the loader needs (`soma_lfe` for the reader,
`soma_tools` transitively for the registry). The runtime never imports it;
the one-way dependency holds.

`soma_tool_config:load_dir(Dir)` does the whole job for one directory:

1. List `Dir/*.lisp`, sorted by name. A missing or unreadable directory
   returns `#{registered => [], skipped => []}` with no log line and no
   registry call — boot stays byte-for-byte unchanged.
2. Per file: read the bytes, parse with `soma_lfe_reader:read_forms/1`,
   expect exactly one `(tool …)` form, compile it to a manifest map, and
   hand that map to `soma_tool_registry:register_tool/1`.
3. Any per-file failure — read error, parse diagnostic, compile error, or a
   `{error, _}` from `register_tool/1` — skips that file: one
   `logger:warning` boot log line plus a `#{file => Basename, reason =>
   NamedReason}` entry in the returned `skipped` list. The loop continues to
   the next file. The return shape is
   `#{registered => [Name], skipped => [SkipEntry]}`.

Key decisions:

- **The loader does not validate manifests itself.** It compiles the form to
  a map and lets `register_tool/1` run `soma_tool_manifest:normalize/1` —
  the exact path built-ins take. A bad `effect` in a tool file therefore
  surfaces the same `{invalid_effect, _}` a bad built-in would, straight
  into the skip diagnostic. Criterion 3 is this decision made testable.
- **The one compile-stage rejection is the adapter.** Any `(adapter X)`
  where `X` is not `cli` fails compilation with a named error
  (`{adapter_not_allowed, X}`) before the manifest ever reaches the
  registry. `(adapter erlang_module)` must not fall through to normalize —
  normalize would only complain about a missing `module` field, and a file
  that *declared* a module would pass. Config files cannot inject modules,
  so the loader closes that door itself.
- **Defaults are filled before registration.** `normalize/1` requires every
  shared field, so the compiler fills `effect => state`,
  `idempotent => false`, `timeout_ms => 30000` for whichever of the three
  the file leaves out. Declared values pass through untouched — including
  invalid ones, so normalize stays the validator.
- **Grammar.** The form is `(tool (key value…) …)` with the allowlisted keys
  `name`, `description`, `effect`, `idempotent`, `timeout-ms`, `adapter`,
  `executable`, `argv`. `name`, `description`, `executable` take one string;
  `argv` takes zero or more strings; `effect`, `idempotent`, `adapter` take
  one symbol; `timeout-ms` takes one integer. `timeout-ms` maps to the
  manifest key `timeout_ms`. A duplicate key, an unknown key (including
  `params` — see Risks), a missing `name`, or a wrong value shape where the
  compiler must transform the value (a non-string `name`) is a named compile
  error. Value shapes normalize already checks (effect membership, boolean,
  integer range) pass through so its error names win.
- **Atoms.** The tool name arrives as a string and becomes an atom in the
  compiler — at boot only, from the user's own trusted local files, bounded
  by file count. (The reader itself mints atoms for symbols; same trust
  argument, and it is the existing reader.) Nothing on the wire changes: an
  unknown tool name in a step still resolves to `{error, not_found}`.
- **Boot wiring.** `soma_cli:daemon/1` and `daemon_foreground/1` both call
  `soma_tool_config:load_dir(resolve_tools_dir(Args))` after
  `application:ensure_all_started(soma_runtime)` (the registry must be up)
  and before the listener starts. `resolve_tools_dir/1` mirrors
  `soma_config`'s path seam: a `tools_dir` key in `Args` wins (the hermetic
  test seam), else `$HOME/.soma/tools`. The result map is not acted on
  beyond the log lines already emitted per skip; a broken tool file never
  stops boot.
- **Diagnostics are log lines + return data, not events.** The design doc
  sketch mentioned an event; the acceptance criteria only require a named,
  bounded diagnostic. Skipping the event keeps the event vocabulary
  unchanged for this slice.

New tests live in `apps/soma_actor/test/soma_tool_config_SUITE.erl` (CT,
booting `soma_runtime` per case the way `soma_cli_adapter_SUITE` does). Dev
may add a pure EUnit module for compile-stage grammar cases; the mapping
below is the contract.

## Acceptance criteria → tests

### Criterion 1 — tools dir loaded at daemon boot registers each valid tool
- Call chain: `soma daemon` → `soma_cli:daemon/1` → `soma_tool_config:load_dir/1`
  → `soma_tool_registry:register_tool/1` → registry state →
  `soma_tool_registry:resolve_descriptor/1`
- Test entry: `soma_cli:daemon/1` (no layer bypassed; a temp `socket` and a
  temp `tools_dir` in `Args` keep it hermetic)
- Code boundary: `apps/soma_actor/src/soma_tool_config.erl` (new) and the
  boot-wiring lines in `apps/soma_actor/src/soma_cli.erl`
- Responsibility owner: `soma_cli` daemon boot owns "config tools load at
  boot"; `soma_tool_config` owns the file → manifest path
- Test: `test_daemon_boot_registers_config_tool` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 2 — declared description appears in catalog/0
- Call chain: `soma_tool_config:load_dir/1` →
  `soma_tool_registry:register_tool/1` → registry state →
  `soma_tool_registry:catalog/0`
- Test entry: `soma_tool_config:load_dir/1` (boot wiring is criterion 1's
  job; entering at the loader drops the socket setup without skipping a
  layer the criterion is about)
- Code boundary: `apps/soma_actor/src/soma_tool_config.erl` (description
  compiles into the manifest; catalog behavior is #203's, unchanged)
- Responsibility owner: `soma_tool_config` owns carrying `description` into
  the manifest; `soma_tool_registry` owns the catalog rule
- Test: `test_config_tool_description_in_catalog` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 3 — invalid manifest field surfaces the normalize error
- Call chain: `soma_tool_config:load_dir/1` → compile →
  `soma_tool_registry:register_tool/1` → `soma_tool_manifest:normalize/1`
  → `{error, {invalid_effect, _}}` → skip entry
- Test entry: `soma_tool_config:load_dir/1` (a file declaring
  `(effect banana)`; assert the skip entry's reason is exactly
  `{invalid_effect, banana}`)
- Code boundary: `apps/soma_actor/src/soma_tool_config.erl` only — the
  loader must pass the value through, not pre-validate it
- Responsibility owner: `soma_tool_manifest:normalize/1` owns manifest
  validation; the loader only carries its error into the diagnostic
- Test: `test_invalid_field_surfaces_normalize_error` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 4 — conservative defaults, declared values win
- Call chain: `soma_tool_config:load_dir/1` → default fill → 
  `soma_tool_registry:register_tool/1` →
  `soma_tool_registry:resolve_descriptor/1`
- Test entry: `soma_tool_config:load_dir/1` (two files: one declaring none
  of `effect`/`idempotent`/`timeout-ms` → `state`/`false`/`30000`; one
  declaring all three → exactly the declared values)
- Code boundary: the default-fill step in
  `apps/soma_actor/src/soma_tool_config.erl`
- Responsibility owner: `soma_tool_config` owns the defaults; the values in
  the resolved descriptor prove it
- Test: `test_safety_defaults_and_declared_values` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 5 — non-cli adapter is rejected with a named diagnostic
- Call chain: `soma_tool_config:load_dir/1` → compile-stage adapter check
  → skip entry (never reaches `register_tool/1`)
- Test entry: `soma_tool_config:load_dir/1` (a file declaring
  `(adapter erlang_module)`; assert the named reason, e.g.
  `{adapter_not_allowed, erlang_module}`, and that the name does not
  resolve)
- Code boundary: the adapter allowlist in
  `apps/soma_actor/src/soma_tool_config.erl`
- Responsibility owner: `soma_tool_config` owns "config files cannot inject
  modules" — this rule is deliberately in front of normalize
- Test: `test_non_cli_adapter_rejected` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 6 — a broken file is skipped, the rest register, the daemon serves
- Call chain: `soma_cli:daemon/1` → `soma_tool_config:load_dir/1` (mixed
  dir: an unparseable file, an invalid-manifest file, a valid file) →
  listener starts → `soma_cli:ping/1` over the socket
- Test entry: `soma_cli:daemon/1` (no layer bypassed — the criterion is
  about boot surviving)
- Code boundary: the per-file skip loop in
  `apps/soma_actor/src/soma_tool_config.erl` and the boot call site in
  `soma_cli.erl`
- Responsibility owner: `soma_tool_config` owns skip-and-continue;
  `soma_cli` owns not letting the loader's result block boot
- Test: `test_broken_file_skipped_daemon_serves` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 7 — missing or empty tools dir leaves boot unchanged
- Call chain: `soma_cli:daemon/1` → `soma_tool_config:load_dir/1` (missing
  path, then an empty dir) → no registry call, no log → listener starts
- Test entry: `soma_cli:daemon/1` (assert the registered tool names equal
  the built-in seed exactly, `load_dir/1` returned the empty result, and
  the daemon answers a ping)
- Code boundary: the missing/empty-dir branch in
  `apps/soma_actor/src/soma_tool_config.erl`
- Responsibility owner: `soma_tool_config` owns the no-op guarantee
- Test: `test_missing_or_empty_dir_boot_unchanged` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`

### Criterion 8 — a config-registered tool runs end-to-end
- Call chain: `soma_agent_session:start_run/2` → `soma_run` →
  `soma_tool_call` → cli adapter (`open_port`, executable + argv) → result
  message → event trail (`tool.started` … `run.completed`)
- Test entry: `soma_agent_session:start_run/2`, after
  `soma_tool_config:load_dir/1` registered a tool file pointing at a real
  helper script (the `write_cli_helper` pattern from
  `soma_cli_adapter_SUITE`) — the same entry the v0.2 cli proofs use, so no
  execution layer is bypassed
- Code boundary: none new — the criterion proves the registered descriptor
  drives the existing adapter unchanged; only `soma_tool_config.erl` feeds it
- Responsibility owner: `soma_run` / `soma_tool_call` own execution; the
  test proves the loader's descriptor is indistinguishable from a
  hand-registered one
- Test: `test_config_tool_runs_end_to_end` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`

## Risks & trade-offs

- **`params` is rejected, not compiled.** The design doc's grammar shows
  `(params …)`, but no criterion here needs it, and compiling its nested
  list shape is real grammar work. Silently dropping a field the user
  declared would be worse than refusing the file, so an unknown key
  (including `params`) skips the file with a named reason. A tool file
  copied straight from the design doc's docmod example will not load until
  the follow-up issue lands. That's the cost of failing closed.
- **A config tool can shadow a built-in.** `register_tool/1` overwrites by
  name, so a file declaring `(name "echo")` replaces the built-in `echo`
  descriptor. The criteria don't cover collisions and the scope is locked,
  so the overwrite semantics stay as they are. Worth a follow-up if it
  bites — the fix would be a loader-side reserved-name check.
- **The reader has no comment syntax.** A `;` comment in a tool file is an
  "unrecognised character" parse diagnostic and the file is skipped. The
  diagnostic names the problem, but users used to Lisp comments will trip
  on it. Extending the reader is out of scope here.
- **No skip event.** Diagnostics are boot log lines plus the loader's return
  value. If trace tooling later needs skip visibility, an event can be
  added then; adding event types now would grow the vocabulary for a
  consumer that doesn't exist.

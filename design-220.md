# soma tool register/list/remove external CLI tools

## Current state

Third-party CLI tools reach Soma one way today: you drop a `(tool ...)` file
into `~/.soma/tools/` and the daemon reads the whole directory at boot.
`soma_cli:daemon/1` calls `soma_tool_config:load_dir/1` after the runtime is up
and before the listener starts. `load_dir/1` compiles each file to a manifest,
runs it through `soma_tool_manifest:normalize/1`, and registers it with
`soma_tool_registry:register_tool/1`. A broken file skips with a named
diagnostic and boot continues.

Two things are missing for a live workflow.

First, there is no way to add, inspect, or drop a tool without editing the
directory by hand and restarting. A third party who ships a CLI wants to
register it against a running daemon and see it resolve immediately.

Second, the socket surface has no tool verbs. `soma_cli_server` dispatches
`run` / `ask` / `trace` / `status` / `cancel` / `stop`, all parsed by
`soma_lfe:compile/2`. The `(tool ...)` manifest form is not a `soma_lfe` form at
all — it is compiled by private functions inside `soma_tool_config`. The server
also does not know the tools directory: `tools_dir` is resolved in `soma_cli`
only at boot and never handed to `soma_cli_server:start_link/1`.

The registry has no removal path. It exposes `register_tool/1`, `resolve/1`,
`resolve_descriptor/1`, and `catalog/1`. `catalog/1` is the wrong projection for
a `list` verb: it only returns `name` / `description` / `params`, and only for
descriptors that carry a description. There is no function that lists every live
tool with its `effect` / `idempotent` / `adapter`, and nothing removes a name.

## Approach

Add three tool verbs to the existing socket surface. Keep them off the actor
path — they run inline in the connection handler the way `trace` and `status`
already do, so no `soma_actor` task is ever started.

**Wire forms.** The client sends one Lisp form per verb over the existing
`{packet, 4}` socket:

- `register`: the client reads the `(tool ...)` manifest file and sends it
  wrapped as `(tool-register (tool ...))`.
- `list`: `(tool-list)`.
- `remove`: `(tool-remove "<name>")`.

The server dispatches these before the `soma_lfe:compile/2` path. The `(tool ...)`
body inside a register request is compiled to a manifest by the same code the
boot loader uses, so a socket register and a boot-file load validate through one
path. That means exposing the compile step `soma_tool_config` keeps private
today (a `compile_form/1`-style entry, or a small shared module) instead of
copying the grammar into the server. Dev picks the exact split; the rule is one
compiler, one normalizer.

**The server learns the tools directory.** `soma_cli_server:start_link/1` gains
a `tools_dir` key, and the two daemon boot paths in `soma_cli`
(`daemon_with_model_config/2`, `daemon_foreground_with_model_config/2`) pass
`resolve_tools_dir(Args)` into it. The handler needs this to write and delete
manifest files. It also needs the event store pid, which it already locates via
`event_store_pid/0`.

**Register admission and side-effect order.** Validate everything before
touching disk or the registry, so a rejected request leaves both untouched.
Order of checks:

1. Compile the `(tool ...)` body and run `soma_tool_manifest:normalize/1`. A
   bad manifest returns normalize's own `{error, Reason}` verbatim.
2. Reserved name: if the declared name is in
   `soma_tool_registry:builtin_names/0`, return `{error, {reserved_name, Name}}`.
3. Already registered: if the name already resolves in the running registry
   (and is not a built-in), return `{error, {already_registered, Name}}`. This
   is a new reason distinct from the loader's per-load `{duplicate_name, Name}`,
   because it is checked against live registry state, not a load accumulator.

Only after all three pass does the handler apply side effects: write the
normalized `(tool ...)` file to `<tools_dir>/<name>.lisp`, register the
descriptor in the running registry, and append one `tool.registered` event.
Writing the normalized manifest back to a `(tool ...)` s-expr is new rendering
work; the file must round-trip so a restart re-registers the same descriptor.

**List projection.** Add a registry function that maps every live descriptor to
`#{name, effect, idempotent, adapter}` plus `description` when present, and
nothing else — never `module` / `executable` / `argv` / `timeout_ms`, and no
process-local values. The server renders that list as the `(tool-list ...)`
reply. Building the projection by constructing each entry from named fields (the
way `catalog/1` does) keeps runtime internals from leaking by accident.

**Remove admission and path safety.** A name is removable only if it resolves in
the running registry and is not a built-in — that is the definition of a config
tool here. A built-in name (or any name that is not a live config tool) returns
`{error, {not_config_tool, Name}}`. The wire carries the name as a binary; map
it to an existing registry atom rather than minting a new atom, so a bogus or
traversal-shaped name simply fails to match a live tool and is rejected before
any deletion. The deleted path is always
`filename:join(ToolsDir, atom_to_list(Name) ++ ".lisp")`, built from the
configured directory plus a basename — never a caller-supplied path — so a remove
can only ever delete inside the tools directory. On success: delete that one
file, remove the name from the running registry (a new registry unregister
call), and append one `tool.removed` event.

**Events.** `tool.registered` and `tool.removed` go through
`soma_event_store:append/2`, which fills the run/session/step ids with
`undefined`. The payload carries the tool name and the safe metadata only
(`effect` / `idempotent` / `adapter`). It must not carry the executable path,
argv values, pids, ports, or refs.

## Acceptance criteria → tests

The socket-driven cases live in a new CT suite `soma_tool_management_SUITE`
(`apps/soma_actor/test/`). Each case boots the daemon through `soma_cli:daemon/1`
with a temp `socket`, a temp `tools_dir`, and a no-LLM `config_path`, then talks
to it over the real socket — the same harness shape as `soma_tool_config_SUITE`.
Stub executables are written into the temp tools dir. Pure projection and
removal cases live in `soma_tool_registry_tests` (`apps/soma_tools/test/`).

### Criterion 1 — register sends the manifest over the socket
- Call chain: `soma_cli_main:dispatch(["tool","register",File])` → `soma_cli` tool-register client → `gen_tcp:send` of the `(tool-register (tool ...))` frame
- Test entry: `soma_cli_main:dispatch/1`, with `soma_cli_request_capture` standing in for the daemon to capture the sent bytes
- Code boundary: `apps/soma_actor/src/soma_cli.erl` and `soma_cli_main.erl` (client verb + argv routing)
- Responsibility owner: `soma_cli` owns the client wire; `soma_cli_main` owns argv routing
- Test: `test_register_sends_manifest_over_socket` in `apps/soma_actor/test/soma_tool_management_SUITE.erl`

### Criterion 2 — a valid register resolves in the running daemon before restart
- Call chain: client register request → `soma_cli_server` handler → compile + normalize + admission → `soma_tool_registry:register_tool/1` → later `resolve_descriptor/1`
- Test entry: `soma_cli_server` socket (real register request, then a real resolve on the same daemon)
- Code boundary: `apps/soma_actor/src/soma_cli_server.erl` register branch
- Responsibility owner: `soma_cli_server` owns the register handler; `soma_tool_registry` owns live registration
- Test: `test_register_tool_resolves_before_restart` in `soma_tool_management_SUITE`

### Criterion 3 — a successful register writes one normalized `<name>.lisp`
- Call chain: client register request → `soma_cli_server` handler → normalize → render `(tool ...)` → `file:write_file(<tools_dir>/<name>.lisp)`
- Test entry: `soma_cli_server` socket, then read back the tools directory
- Code boundary: `soma_cli_server` register handler + the normalized-manifest renderer
- Responsibility owner: `soma_cli_server` owns persistence into the configured tools dir
- Test: `test_register_writes_normalized_manifest_file` in `soma_tool_management_SUITE`

### Criterion 4 — a restart after register resolves from the persisted file
- Call chain: register (writes file) → daemon stop → `soma_cli:daemon/1` boot → `soma_tool_config:load_dir/1` reads the file → `resolve_descriptor/1`
- Test entry: `soma_cli_server` socket for register, `soma_cli:daemon/1` for the restart boot
- Code boundary: `soma_cli_server` register persistence + the existing `soma_tool_config:load_dir/1` boot path
- Responsibility owner: `soma_tool_config` owns boot-time load; the persisted file is the hand-off
- Test: `test_restart_after_register_resolves_from_file` in `soma_tool_management_SUITE`

### Criterion 5 — an invalid manifest returns normalize's own `{error, _}`
- Call chain: client register request → `soma_cli_server` handler → compile → `soma_tool_manifest:normalize/1` returns `{error, Reason}` → handler surfaces `Reason` verbatim
- Test entry: `soma_cli_server` socket with a manifest carrying a bad field (e.g. `effect banana`), asserting the wire reason equals `{invalid_effect, banana}`
- Code boundary: `soma_cli_server` register error rendering
- Responsibility owner: `soma_tool_manifest` owns the validation reason; `soma_cli_server` must not rename it
- Test: `test_register_invalid_manifest_returns_normalize_error` in `soma_tool_management_SUITE`

### Criterion 6 — a failed register leaves the tools directory unchanged
- Call chain: client register request → `soma_cli_server` handler → validation fails before any `file:write_file`
- Test entry: `soma_cli_server` socket, then read the tools directory (unchanged)
- Code boundary: `soma_cli_server` register handler (validate-before-side-effect ordering)
- Responsibility owner: `soma_cli_server` owns the side-effect ordering
- Test: `test_failed_register_leaves_tools_dir_unchanged` in `soma_tool_management_SUITE`

### Criterion 7 — a failed register leaves the registry without the rejected tool
- Call chain: client register request → `soma_cli_server` handler → validation fails before `register_tool/1` → `resolve_descriptor/1` returns `{error, not_found}`
- Test entry: `soma_cli_server` socket, then a real resolve for the rejected name
- Code boundary: `soma_cli_server` register handler
- Responsibility owner: `soma_cli_server` gates before touching the live registry
- Test: `test_failed_register_leaves_registry_clean` in `soma_tool_management_SUITE`

### Criterion 8 — a built-in name returns `{reserved_name, Name}`
- Call chain: client register request → `soma_cli_server` handler → `soma_tool_registry:builtin_names/0` membership → `{error, {reserved_name, Name}}`
- Test entry: `soma_cli_server` socket registering a manifest named `echo`
- Code boundary: `soma_cli_server` register admission gate
- Responsibility owner: `soma_tool_registry:builtin_names/0` is the reserved-set source of truth
- Test: `test_register_builtin_name_reserved` in `soma_tool_management_SUITE`

### Criterion 9 — an existing config tool returns `{already_registered, Name}`
- Call chain: register a config tool once → register the same name again → `soma_cli_server` handler → live-registry membership → `{error, {already_registered, Name}}`
- Test entry: `soma_cli_server` socket, two register requests for one name
- Code boundary: `soma_cli_server` register admission gate
- Responsibility owner: `soma_cli_server` owns the live-duplicate check against `resolve_descriptor/1`
- Test: `test_register_existing_config_tool_already_registered` in `soma_tool_management_SUITE`

### Criterion 10 — list returns name/effect/idempotent/adapter/optional description
- Call chain: client `(tool-list)` request → `soma_cli_server` handler → registry list projection → rendered reply
- Test entry: `soma_cli_server` socket for the end-to-end reply; the projection shape is also pinned as a unit
- Code boundary: `apps/soma_tools/src/soma_tool_registry.erl` (new list projection) + `soma_cli_server` list branch
- Responsibility owner: `soma_tool_registry` owns the projection; `soma_cli_server` renders it
- Test: `test_list_returns_summary_fields` in `soma_tool_management_SUITE`; `list_projection_includes_summary_fields_test` in `apps/soma_tools/test/soma_tool_registry_tests.erl`

### Criterion 11 — list omits module/executable/argv/timeout_ms/pid/port/ref
- Call chain: client `(tool-list)` request → `soma_cli_server` handler → registry list projection (named-field construction) → reply
- Test entry: `soma_cli_server` socket asserting the reply bytes carry none of those fields; the projection omission is also pinned as a unit
- Code boundary: `soma_tool_registry` list projection
- Responsibility owner: `soma_tool_registry` builds each entry from named safe fields only
- Test: `test_list_omits_internal_fields` in `soma_tool_management_SUITE`; `list_projection_omits_internal_fields_test` in `soma_tool_registry_tests`

### Criterion 12 — remove makes a config tool unresolved in the running daemon
- Call chain: register a config tool → client `(tool-remove "name")` → `soma_cli_server` handler → registry unregister → `resolve_descriptor/1` returns `{error, not_found}`
- Test entry: `soma_cli_server` socket, then a real resolve on the same daemon
- Code boundary: `soma_tool_registry` (new unregister call) + `soma_cli_server` remove branch
- Responsibility owner: `soma_tool_registry` owns live removal; `soma_cli_server` owns the verb
- Test: `test_remove_config_tool_unresolved` in `soma_tool_management_SUITE`

### Criterion 13 — a successful remove deletes only the owned manifest file
- Call chain: register (writes `<name>.lisp`) → remove → `soma_cli_server` handler → `file:delete(<tools_dir>/<name>.lisp)`
- Test entry: `soma_cli_server` socket, with an unrelated neighbour file in the tools dir asserted intact
- Code boundary: `soma_cli_server` remove handler (path built from tools dir + basename)
- Responsibility owner: `soma_cli_server` owns file deletion scoped to the configured dir
- Test: `test_remove_deletes_only_owned_manifest_file` in `soma_tool_management_SUITE`

### Criterion 14 — remove of a built-in returns `{not_config_tool, Name}`
- Call chain: client `(tool-remove "echo")` → `soma_cli_server` handler → built-in / non-config-tool check → `{error, {not_config_tool, Name}}`
- Test entry: `soma_cli_server` socket removing `echo`
- Code boundary: `soma_cli_server` remove admission gate
- Responsibility owner: `soma_cli_server` owns the config-tool check against `builtin_names/0` and the live registry
- Test: `test_remove_builtin_not_config_tool` in `soma_tool_management_SUITE`

### Criterion 15 — remove never deletes a path outside the tools directory
- Call chain: client `(tool-remove "<traversal-shaped name>")` → `soma_cli_server` handler → name fails to match a live config tool → rejected, no deletion
- Test entry: `soma_cli_server` socket with a name carrying path separators / `..`, plus a sentinel file outside the tools dir asserted intact
- Code boundary: `soma_cli_server` remove handler (name→existing-atom mapping, basename-only path)
- Responsibility owner: `soma_cli_server` constructs the delete path from the configured dir alone
- Test: `test_remove_never_deletes_outside_tools_dir` in `soma_tool_management_SUITE`

### Criterion 16 — a restart after remove keeps the tool unresolved
- Call chain: register → remove (deletes file) → daemon stop → `soma_cli:daemon/1` boot → `load_dir/1` finds no file → `resolve_descriptor/1` returns `{error, not_found}`
- Test entry: `soma_cli_server` socket for register/remove, `soma_cli:daemon/1` for the restart boot
- Code boundary: `soma_cli_server` remove persistence + existing `load_dir/1` boot path
- Responsibility owner: `soma_tool_config` owns boot load; the absent file is the hand-off
- Test: `test_restart_after_remove_stays_unresolved` in `soma_tool_management_SUITE`

### Criterion 17 — a successful register appends one bounded `tool.registered` event
- Call chain: register → `soma_cli_server` handler → `soma_event_store:append/2` with `event_type => <<"tool.registered">>`
- Test entry: `soma_cli_server` socket, then read the event store and count `tool.registered`
- Code boundary: `soma_cli_server` register handler event emission
- Responsibility owner: `soma_cli_server` emits the event; `soma_event_store` stores it
- Test: `test_register_appends_bounded_event` in `soma_tool_management_SUITE`

### Criterion 18 — a successful remove appends one bounded `tool.removed` event
- Call chain: register → remove → `soma_cli_server` handler → `soma_event_store:append/2` with `event_type => <<"tool.removed">>`
- Test entry: `soma_cli_server` socket, then read the event store and count `tool.removed`
- Code boundary: `soma_cli_server` remove handler event emission
- Responsibility owner: `soma_cli_server` emits the event
- Test: `test_remove_appends_bounded_event` in `soma_tool_management_SUITE`

### Criterion 19 — tool-management events omit executable/argv/pids/ports/refs
- Call chain: register + remove → `soma_cli_server` handler → `append/2` with a scrubbed payload
- Test entry: `soma_cli_server` socket, then inspect the stored `tool.registered` / `tool.removed` payloads for absence of executable/argv/pid/port/ref
- Code boundary: `soma_cli_server` event payload construction
- Responsibility owner: `soma_cli_server` builds the payload from safe fields only
- Test: `test_tool_events_omit_sensitive_fields` in `soma_tool_management_SUITE`

### Criterion 20 — a register request starts no `soma_actor` task
- Call chain: register → `soma_cli_server` handler runs inline (no `soma_actor_sup:start_actor`)
- Test entry: `soma_cli_server` socket, comparing `soma_actor_sup` children before and after the register
- Code boundary: `soma_cli_server` register branch (inline, off the actor path)
- Responsibility owner: `soma_cli_server` handles the verb without an actor
- Test: `test_register_starts_no_actor_task` in `soma_tool_management_SUITE`

### Criterion 21 — the new tests drive the real socket with temp dirs / stub executables
- Call chain: none (suite harness invariant)
- Test entry: off chain — this is a property of every case's setup, not a single behavior. Reason: it constrains how the suite is built, not a daemon code path.
- Code boundary: `apps/soma_actor/test/soma_tool_management_SUITE.erl` (`init_per_testcase` boots a real daemon with temp `socket` + `tools_dir` and writes a stub executable)
- Responsibility owner: the suite harness
- Test: the shared setup in `soma_tool_management_SUITE`, exercised by `test_register_tool_resolves_before_restart` (a representative real-socket case)

### Criterion 22 — the tool-config contract maps each new behavior to a test
- Call chain: none (direct source-file read)
- Test entry: off chain — the test reads `docs/contracts/tool-config-test-contract.md`. Reason: it is a doc-drift guard, not a runtime path.
- Code boundary: `docs/contracts/tool-config-test-contract.md` and `apps/soma_actor/test/soma_tool_config_contract_tests.erl`
- Responsibility owner: the contract doc owns the mapping; the doc test guards it
- Test: `test_tool_config_contract_maps_tool_management_proofs` in `apps/soma_actor/test/soma_tool_config_contract_tests.erl`

## Risks & trade-offs

The register path adds a second entry into `soma_tool_config`'s compile logic.
If Dev copies the grammar into `soma_cli_server` instead of exposing it, a socket
register and a boot-file load could drift apart — two validators for one form.
The design says one compiler on purpose; keep it that way even if exposing the
function is slightly more work.

Writing a normalized manifest back to `(tool ...)` and reading it at boot is a
round-trip. If the renderer drops a field the normalizer needs, the
before-restart resolve (criterion 2) passes while the after-restart resolve
(criterion 4) fails. Those two criteria are deliberately separate so the
round-trip is actually exercised, not assumed.

`{already_registered, Name}` for a live duplicate and `{duplicate_name, Name}`
for a within-boot-load duplicate are two different reasons for two different
checks. That is a small vocabulary cost. Collapsing them would be wrong: one is
against live registry state, the other against a per-load accumulator, and the
issue names `already_registered` for the socket case.

Remove decides "config tool" as "resolves and is not built-in." That is correct
for this issue because every config tool has a backing file. If a future change
ever registers a tool live without a file, remove would try to delete a file
that was never written; `file:delete` on a missing path is harmless, but the
model would need revisiting then. It is out of scope here.

# Review notes — issue #220 (round 2)

Round 1 raised two Real issues. Both are fixed by 7413eae: `soma tool list` /
`soma tool remove <name>` now dispatch through `soma_cli:tool_list/1` /
`tool_remove/1` (proven by `test_cli_client_tool_list_and_remove_reach_daemon`),
and a register into a never-created tools dir persists first, creates the dir,
and replies instead of crashing (proven by
`test_register_into_missing_tools_dir_creates_it`). The reordering that fixed
issue 2 introduced a new crash. Details below.

### Claude

## Verdict
changes-requested

## Real issues

1. **A register whose manifest omits `executable` or `argv` crashes the handler
   with no reply, then crashes the client.**
   Reproduced live: send `(tool-register (tool (name "crashcase")))` over the
   socket → the handler dies with `function_clause` in `render_tool_manifest`
   (soma_cli_server.erl:260, called from `register_normalized_tool` at :223) →
   the socket closes with no reply → the client's `{ok, Reply} = gen_tcp:recv`
   in `soma_cli:tool_register/1` badmatches and the escript crashes. Client-side
   observation: `gen_tcp:recv` returns `{error, closed}`.
   Root cause: 7413eae moved the file write before `register_tool/1`, but
   normalize — the only validator that requires `executable`/`argv` for a cli
   tool (soma_tool_manifest.erl:61) — runs *inside* `register_tool/1`.
   `compile_form/1` requires only `name` (`build_manifest`), and
   `render_tool_manifest/1` has one clause that pattern-requires
   `executable`/`argv`. So the render runs on a manifest normalize never saw.
   Before 7413eae this path returned normalize's missing-key error as a clean
   reply; now it's a crash. The suite never catches it because every test
   manifest carries both fields.
   Fix: call `soma_tool_manifest:normalize/1` in the handler right after
   `compile_form/1`, reply with its error verbatim (criterion 5's contract),
   and only then write + register. That also restores design-220.md's stated
   order ("validate everything before touching disk") — today a rejected
   `invalid_effect` register writes a file into the tools dir and deletes it
   again, because the write runs before normalize.

2. **Remove ignores the manifest-delete result, so the reply and the durable
   state can contradict.** `handle_tool_remove` (soma_cli_server.erl:332) does
   `_ = delete_manifest_file(...)`. On `{error, eacces}` (root-owned file,
   read-only dir) the client is told `(status removed)`, the registry drops the
   name — and the surviving file re-registers the tool at the next boot. Silent
   resurrection. This is the same disease round 1 flagged on the register side:
   the caller is told one thing, restart says another. Criterion 16 holds only
   on the happy path. Fix: tolerate `enoent` alone; any other delete error is a
   named error reply, and the delete goes before the unregister so a failure
   leaves live and durable state consistent.

## Questions

1. Concurrent registers of the same name still race: two handlers both pass the
   `resolve_descriptor` not-found gate, both write, both register, two
   `tool.registered` events. Single-user daemon — accepted, or worth
   serializing through the registry?
2. `tools_dir` still defaults to `undefined` in `soma_cli_server:start_link/1`;
   a register on a server started without it writes to a literal
   `undefined/<name>.lisp` relative to the daemon cwd. Both boot paths pass it
   today — reject register/remove when unset, or drop the optional default?

## Nits

- `handle_tool_list` replies `(tool-list ...)` while every other verb replies
  `(result ...)`. Inconsistent wire shape.
- `ok = append_tool_registered_event(...)` / `ok = append_tool_removed_event(...)`
  crash the handler after the side effects if the store call fails; low risk
  (supervised local gen_server), same class as Real issue 1's no-reply crash.
- `soma_tool_config`'s module doc now lies: "the tool name … becomes an atom
  here — at boot only … Nothing on the wire mints atoms." `compile_form/1` runs
  on wire input and `build_manifest` mints the name atom via `binary_to_atom`.
  (The Lisp reader already mints atoms from every wire symbol, so no new attack
  class — but fix the comment.)
- `tool_register/1`, `tool_list/1`, `tool_remove/1` return 0 unconditionally:
  `soma tool register bad.lisp` prints the error reply and exits 0, so scripts
  cannot gate on it. `run` and `stop` check their reply status; the tool verbs
  should too.

## Functional evidence

Gate: `rebar3 eunit --module=soma_tool_registry_tests,soma_tool_config_contract_tests` → 13 tests, 0 failures. `rebar3 ct --suite apps/soma_actor/test/soma_tool_management_SUITE` → All 23 tests passed.

- Criterion 1 — pass: "`soma tool register <manifest.lisp>` sends the manifest over the existing local Lisp socket." — `test_register_sends_manifest_over_socket` drives `soma_cli_main:dispatch(["tool","register",File,"--socket",Path])` against a capture daemon stand-in and matches the wire bytes: `^\(tool-register `, `\(name "cfg_upper"\)`, exit 0.
- Criterion 2 — pass: "A valid register request makes the named CLI tool resolve in the running daemon before any restart." — `test_register_tool_resolves_before_restart`: `resolve_descriptor(mgmt_upper)` is `{error, not_found}` at boot, `{ok, #{adapter := cli}}` after one real socket register, no restart.
- Criterion 3 — pass: "A successful register request writes one normalized `(tool ...)` file to the configured tools directory as `<name>.lisp`." — `test_register_writes_normalized_manifest_file`: after register the tools dir lists exactly `[mgmt_writer.lisp]`, and the file round-trips through `soma_lfe_reader:read_forms/1` + `soma_tool_config:compile_form/1` to `{ok, #{name := mgmt_writer, adapter := cli}}`.
- Criterion 4 — pass: "A daemon restart after register resolves the tool from the persisted file." — `test_restart_after_register_resolves_from_file`: register, `(stop)`, `application:stop(soma_runtime)`, fresh `soma_cli:daemon/1` on the same tools dir, `resolve_descriptor(mgmt_reboot)` returns the cli descriptor again. `test_register_into_missing_tools_dir_creates_it` adds the fresh-install path: a never-created tools dir is created and the file persisted.
- Criterion 5 — fail: "A register request with an invalid manifest returns the same named `{error, _}` reason from `soma_tool_manifest:normalize/1`." — holds only for manifests carrying `executable`/`argv` (`test_register_invalid_manifest_returns_normalize_error` proves `{invalid_effect, banana}` verbatim). A manifest missing `executable`/`argv` — invalid per normalize (soma_tool_manifest.erl:61) — crashes the handler with `function_clause` in `render_tool_manifest` and returns no reply at all; live repro shows the client recv as `{error, closed}`. Real issue 1.
- Criterion 6 — pass: "A failed register request leaves the configured tools directory unchanged." — `test_failed_register_leaves_tools_dir_unchanged`: sorted listing before the rejected register equals the listing after. (Post-7413eae the reject path transiently writes then deletes the file; the end state is unchanged. Real issue 1's fix removes the transient write.)
- Criterion 7 — pass: "A failed register request leaves the running registry without the rejected tool." — `test_failed_register_leaves_registry_clean`: `resolve_descriptor(mgmt_reject)` is `{error, not_found}` before and after the rejected register on the same daemon.
- Criterion 8 — pass: "A register request for a built-in name returns `{error, {reserved_name, Name}}`." — `test_register_builtin_name_reserved`: registering `(name "echo")` returns `(status error)` carrying the rendering of `{reserved_name, echo}`.
- Criterion 9 — pass: "A register request for an existing config tool returns `{error, {already_registered, Name}}`." — `test_register_existing_config_tool_already_registered`: first register of `mgmt_dup` succeeds; the second returns `{already_registered, mgmt_dup}` verbatim.
- Criterion 10 — pass: "`soma tool list` returns each live tool as `name`/`effect`/`idempotent`/`adapter`/optional `description`." — `soma_cli_main:dispatch/1` now has the `["tool", "list" | Flags]` clause driving `soma_cli:tool_list/1`; `test_cli_client_tool_list_and_remove_reach_daemon` runs that client func against a live daemon (exit 0), and `test_list_returns_summary_fields` pins all 7 entries field-for-field in the reply.
- Criterion 11 — pass: "`soma tool list` omits `module`/`executable`/`argv`/`timeout_ms`/pid/port/ref fields." — `test_list_omits_internal_fields` scans the reply bytes for every forbidden form plus `/bin/echo`/`scrub-argv-value`/`4321`; `list_projection_omits_internal_fields_test` plants pid/ref/port keys in a descriptor and the projection (built from named fields only) strips them.
- Criterion 12 — pass: "`soma tool remove <name>` makes a config-registered tool unresolved in the running daemon." — the `["tool", "remove", Name | Flags]` dispatch clause drives `soma_cli:tool_remove/1`; `test_cli_client_tool_list_and_remove_reach_daemon` removes `mgmt_client_verbs` through that client func and `resolve_descriptor` flips to `{error, not_found}`; `test_remove_config_tool_unresolved` proves the same at the socket.
- Criterion 13 — pass: "A successful remove request deletes only the manifest file owned by the configured tools directory." — `test_remove_deletes_only_owned_manifest_file`: `mgmt_delfile.lisp` reads `{error, enoent}` after remove while the neighbour file in the same dir survives byte-for-byte.
- Criterion 14 — pass: "A remove request for a built-in tool returns `{error, {not_config_tool, Name}}`." — `test_remove_builtin_not_config_tool`: `(tool-remove "echo")` returns `{not_config_tool, echo}` (the existing atom) and `echo` still resolves.
- Criterion 15 — pass: "A remove request never deletes a path outside the configured tools directory." — `test_remove_never_deletes_outside_tools_dir`: `../sentinel` and an absolute-path name both return `(status error)`; the sentinel above the tools dir survives byte-for-byte. `config_tool_name/1` maps the wire binary onto live non-built-in registry atoms only; the delete path is always tools dir + basename.
- Criterion 16 — pass: "A daemon restart after remove keeps the removed tool unresolved." — `test_restart_after_remove_stays_unresolved`: register + remove, daemon stop + runtime reset, fresh boot on the same tools dir, `resolve_descriptor(mgmt_purged)` stays `{error, not_found}`. (Happy path only — a failed delete silently resurrects; Real issue 2.)
- Criterion 17 — pass: "A successful register request appends one bounded `tool.registered` event." — `test_register_appends_bounded_event`: zero such events before, exactly one after; payload key set pinned to exactly `[adapter, effect, idempotent, tool_name]`.
- Criterion 18 — pass: "A successful remove request appends one bounded `tool.removed` event." — `test_remove_appends_bounded_event`: register appends no `tool.removed`; the remove appends exactly one, payload keys exactly `[tool_name]`.
- Criterion 19 — pass: "Tool-management events omit executable paths/argv values/pids/ports/refs." — `test_tool_events_omit_sensitive_fields`: deep term scan over both stored events finds no pid/port/ref/fun; no `executable`/`argv`/`module`/`timeout_ms` keys; `/bin/echo`, `scrub-argv-value`, `4321` never appear in the rendered payload bytes.
- Criterion 20 — pass: "A `soma tool register` socket request completes without starting a `soma_actor` task." — `test_register_starts_no_actor_task`: `soma_actor_child_sup` children snapshot before a full successful register equals the snapshot after.
- Criterion 21 — pass: "The new tool-management tests drive the real socket surface with temp tools directories/stub executables." — `init_per_testcase` builds a per-case temp base dir (pid + unique integer) holding the socket path and a mode-0755 `#!/bin/sh` stub; `test_harness_drives_real_socket_with_temp_dirs_and_stub` registers a tool over the real socket whose resolved `executable` is that stub file.
- Criterion 22 — pass: "The tool-config contract maps each new `soma tool` behavior to a proving test case." — `docs/contracts/tool-config-test-contract.md`'s "Tool Management Contract" table maps the behaviors to their cases; `tool_config_contract_maps_tool_management_proofs_test` asserts every case name appears in the doc (green in the eunit run above).

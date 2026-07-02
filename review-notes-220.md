# Review notes — issue #220

### Claude

## Verdict
changes-requested

## Real issues

1. **`soma tool list` and `soma tool remove <name>` don't exist as commands.**
   `soma_cli_main:dispatch/1` has one tool clause — `["tool", "register", File | Flags]`.
   `soma tool list` and `soma tool remove foo` fall through to `usage()` and exit 2.
   The usage string still reads `soma <run|ask|status|trace|cancel|stop|daemon>` — no `tool` at all.
   The server handles `(tool-list)` and `(tool-remove "...")`, and the tests prove it — by hand-rolling
   `gen_tcp` frames in the suite. No user can reach those verbs. The design's wire-forms section says
   "The client sends one Lisp form per verb"; only one of three verbs got a client. Criteria 10–12 name
   the commands, not the socket forms. Add the two dispatch clauses + client funcs (mirror
   `tool_register/1`) and update the usage line.

2. **First register on a fresh install mutates the registry, then crashes the handler with no reply.**
   `register_normalized_tool` (soma_cli_server.erl) runs `register_tool` first, then
   `ok = write_manifest_file(...)`. Nothing ever creates the default tools dir `~/.soma/tools`
   (`load_dir/1` deliberately tolerates a missing dir; zero `ensure_dir` calls in `apps/soma_actor/src`).
   So on a machine where the user never made that dir by hand: `file:write_file` → `{error, enoent}` →
   badmatch → handler process dies → socket closes with no reply → the client's own
   `{ok, Reply} = gen_tcp:recv(...)` badmatches and the escript crashes. Net state: tool registered
   live, no file on disk, no `tool.registered` event — and the next restart silently drops the tool.
   The design also ordered it the other way (write file, then register) so a write failure leaves the
   registry untouched. Fix: `filelib:ensure_dir` the target, check the write result, reply with a named
   `{error, _}` instead of crashing, and restore the write-before-register order so a disk failure
   can't leave a live-only registration.

## Questions

1. Concurrent registers of the same name race: two handlers both pass the `resolve_descriptor`
   not-found gate, both call `register_tool` (the registry overwrites by name), two files are written,
   two `tool.registered` events land. Single-user daemon — accepted, or worth serializing through the
   registry?
2. `tools_dir` is optional in `soma_cli_server:start_link/1` and defaults to `undefined`. A register
   against a server started without it writes to a literal `undefined/<name>.lisp` relative to the
   daemon cwd (`filename:join/2` stringifies atoms). Both daemon boot paths pass it today — is the
   optional default worth keeping, or should the register/remove branches reject when unset?

## Nits

- `handle_tool_list` replies with a bare `(tool-list ...)` while every other verb replies
  `(result ...)`. Inconsistent wire shape; fine while the client prints raw bytes, awkward the day
  anything parses replies generically.
- `ok = append_tool_registered_event(...)` / `ok = append_tool_removed_event(...)` crash the handler
  after the side effects if the event store call fails — same class as Real issue 2, lower risk since
  the store is a supervised local gen_server.

## Functional evidence

Gate: `rebar3 eunit --module=soma_tool_registry_tests,soma_tool_config_contract_tests` → 13 tests, 0 failures. `rebar3 ct --suite apps/soma_actor/test/soma_tool_management_SUITE` → All 21 tests passed.

- Criterion 1 — pass: "`soma tool register <manifest.lisp>` sends the manifest over the existing local Lisp socket." — `test_register_sends_manifest_over_socket` drives `soma_cli_main:dispatch(["tool","register",File,"--socket",Path])` against a `soma_cli_request_capture` daemon stand-in and matches the captured wire bytes: `^\(tool-register `, `\(tool`, `\(name "cfg_upper"\)`, exit 0.
- Criterion 2 — pass: "A valid register request makes the named CLI tool resolve in the running daemon before any restart." — `test_register_tool_resolves_before_restart`: `resolve_descriptor(mgmt_upper)` is `{error, not_found}` at boot, then `{ok, #{adapter := cli, executable := "/bin/echo"}}` after one real socket register, no restart.
- Criterion 3 — pass: "A successful register request writes one normalized `(tool ...)` file to the configured tools directory as `<name>.lisp`." — `test_register_writes_normalized_manifest_file`: tools dir empty at boot; after register the wildcard lists exactly `[mgmt_writer.lisp]`, and the file re-reads through `soma_lfe_reader:read_forms/1` + `soma_tool_config:compile_form/1` to `{ok, #{name := mgmt_writer, adapter := cli}}`.
- Criterion 4 — pass: "A daemon restart after register resolves the tool from the persisted file." — `test_restart_after_register_resolves_from_file`: register, `(stop)` over the socket, `application:stop(soma_runtime)` (live registration gone), fresh `soma_cli:daemon/1` on the same tools dir, `resolve_descriptor(mgmt_reboot)` returns the cli descriptor again.
- Criterion 5 — pass: "A register request with an invalid manifest returns the same named `{error, _}` reason from `soma_tool_manifest:normalize/1`." — `test_register_invalid_manifest_returns_normalize_error`: computes normalize's own `{invalid_effect, banana}` for the exact manifest, then asserts the wire reply carries that rendering verbatim inside `(status error)`.
- Criterion 6 — pass: "A failed register request leaves the configured tools directory unchanged." — `test_failed_register_leaves_tools_dir_unchanged`: sorted directory listing before the rejected register equals the listing after; no `mgmt_nowrite.lisp` exists.
- Criterion 7 — pass: "A failed register request leaves the running registry without the rejected tool." — `test_failed_register_leaves_registry_clean`: `resolve_descriptor(mgmt_reject)` is `{error, not_found}` both before and after the rejected register on the same running daemon.
- Criterion 8 — pass: "A register request for a built-in name returns `{error, {reserved_name, Name}}`." — `test_register_builtin_name_reserved`: registering `(name "echo")` returns `(status error)` carrying the exact rendering of `{reserved_name, echo}`.
- Criterion 9 — pass: "A register request for an existing config tool returns `{error, {already_registered, Name}}`." — `test_register_existing_config_tool_already_registered`: first register of `mgmt_dup` succeeds and resolves; the second returns `(status error)` carrying `{already_registered, mgmt_dup}` verbatim.
- Criterion 10 — fail: "`soma tool list` returns each live tool as `name`/`effect`/`idempotent`/`adapter`/optional `description`." — the command does not exist: `soma_cli_main:dispatch/1` has no `["tool", "list" | _]` clause, so `soma tool list` prints the usage message and exits 2. The socket form works (`test_list_returns_summary_fields` pins all 7 entries field-for-field over a raw `gen_tcp` frame), but only the test suite can send it.
- Criterion 11 — fail: "`soma tool list` omits `module`/`executable`/`argv`/`timeout_ms`/pid/port/ref fields." — the scrub property is proven at the socket and projection level (`test_list_omits_internal_fields` scans the reply bytes for every forbidden form plus `/bin/echo`/`scrub-argv-value`/`4321`; `list_projection_omits_internal_fields_test` plants pid/ref/port keys in a descriptor and the projection strips them), but the `soma tool list` command the criterion names does not exist (see Criterion 10).
- Criterion 12 — fail: "`soma tool remove <name>` makes a config-registered tool unresolved in the running daemon." — no `["tool", "remove" | _]` dispatch clause; `soma tool remove mgmt_gone` prints usage, exit 2. The socket form works (`test_remove_config_tool_unresolved`: `(tool-remove "mgmt_gone")` → `(status removed)` → `resolve_descriptor(mgmt_gone)` = `{error, not_found}`), but no user can send it.
- Criterion 13 — pass: "A successful remove request deletes only the manifest file owned by the configured tools directory." — `test_remove_deletes_only_owned_manifest_file`: after remove, `mgmt_delfile.lisp` reads `{error, enoent}` while the neighbour file in the same tools dir survives byte-for-byte.
- Criterion 14 — pass: "A remove request for a built-in tool returns `{error, {not_config_tool, Name}}`." — `test_remove_builtin_not_config_tool`: `(tool-remove "echo")` returns `(status error)` carrying the rendering of `{not_config_tool, echo}` (the existing built-in atom), and `echo` still resolves afterwards.
- Criterion 15 — pass: "A remove request never deletes a path outside the configured tools directory." — `test_remove_never_deletes_outside_tools_dir`: both `../sentinel` and an absolute-path name return `(status error)` (never `removed`), and the sentinel file one level above the tools dir survives byte-for-byte; the handler maps the wire binary onto existing live-tool atoms only and builds the delete path from the configured dir plus a basename.
- Criterion 16 — pass: "A daemon restart after remove keeps the removed tool unresolved." — `test_restart_after_remove_stays_unresolved`: register + remove, daemon stop + runtime reset, fresh boot on the same tools dir, `resolve_descriptor(mgmt_purged)` stays `{error, not_found}`.
- Criterion 17 — pass: "A successful register request appends one bounded `tool.registered` event." — `test_register_appends_bounded_event`: store holds zero such events before, exactly one after; run/session/step ids are `undefined` and the payload key set is pinned to exactly `[adapter, effect, idempotent, tool_name]`.
- Criterion 18 — pass: "A successful remove request appends one bounded `tool.removed` event." — `test_remove_appends_bounded_event`: register appends no `tool.removed`; the remove appends exactly one, payload key set pinned to exactly `[tool_name]`.
- Criterion 19 — pass: "Tool-management events omit executable paths/argv values/pids/ports/refs." — `test_tool_events_omit_sensitive_fields`: a deep term scan over both stored events finds no pid/port/ref/fun; the payloads carry no `executable`/`argv`/`module`/`timeout_ms` keys; the distinctive values `/bin/echo`, `scrub-argv-value`, `4321` never appear in the rendered payload bytes.
- Criterion 20 — pass: "A `soma tool register` socket request completes without starting a `soma_actor` task." — `test_register_starts_no_actor_task`: `soma_actor_child_sup` children snapshot before a full successful register equals the snapshot after.
- Criterion 21 — pass: "The new tool-management tests drive the real socket surface with temp tools directories/stub executables." — `init_per_testcase` builds a per-case temp base dir (pid + unique integer) holding the socket path and a mode-0755 `#!/bin/sh` stub; `test_harness_drives_real_socket_with_temp_dirs_and_stub` registers a tool over the real socket whose resolved descriptor's `executable` is that stub file.
- Criterion 22 — pass: "The tool-config contract maps each new `soma tool` behavior to a proving test case." — `docs/contracts/tool-config-test-contract.md` gained a "Tool Management Contract" table mapping all 21 behaviors to their cases; `tool_config_contract_maps_tool_management_proofs_test` in `soma_tool_config_contract_tests` asserts every case name appears in the doc (green in the eunit run above).

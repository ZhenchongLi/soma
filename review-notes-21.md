### Claude

## Verdict
approve

## Real issues
None.

## Questions
- Criterion 2's test asserts the child cwd differs from the runtime cwd and is a real directory. It never asserts the cwd equals `adapter_cwd()`. The pin holds — any directory the child reports that isn't the runtime cwd came from the `{cd, _}` option — but a tighter check (child cwd == `adapter_cwd()`) would catch a future edit that swaps the temp dir for something else. Not a blocker.
- `kill_os_process/1` treats an unresolvable `kill` as a no-op (`os:find_executable` returns `false`). On the Linux release targets `kill` is present, so the lifecycle suite still proves the child is gone. If a target ever ships without `kill` on PATH, teardown silently leaves the child running. Out of scope for v0.2, flagged for the record.

## Nits
- `minimal_env/0` rebuilds the cleared-env list on every cli launch by walking `os:env()`. Per-launch cost, not user-visible at v0.1 volumes.

## Functional evidence
- Criterion 1 — pass: `test_cli_child_env_omits_runtime_var` sets `SOMA_CLI_ENV_LEAK_MARKER=leaked-value` with `os:putenv/2`, runs a helper that prints `$SOMA_CLI_ENV_LEAK_MARKER`, asserts recorded step output is `<<>>`. `minimal_env/0` clears every inherited var with `{Name, false}` and re-adds only PATH. Green in CT (59 passed).
- Criterion 2 — pass: `test_cli_child_cwd_is_adapter_dir` runs a `pwd` helper, asserts `ChildCwd =/= RuntimeCwd` and the child cwd is a real directory. `open_cli_port/2` passes `{cd, adapter_cwd()}` where `adapter_cwd()` is `filename:basedir(user_cache, "soma_cli")`. Green in CT.
- Criterion 3 — pass: `test_cli_argv_redirect_is_literal` sends argv `[">", TargetFile]`, asserts output contains literal `>` and the filename, and `filelib:is_file(TargetFile)` is `false` after the run. Green in CT.
- Criterion 4 — pass: `test_cli_argv_semicolon_is_literal` sends argv `[";", "touch", TargetFile]`, asserts output contains literal `;`, `touch`, the filename, and no file at `TargetFile`. Green in CT.
- Criterion 5 — pass: `test_cli_argv_home_is_literal` sends argv `["$HOME"]`, asserts output is exactly `<<"$HOME">>` and `=/= list_to_binary(os:getenv("HOME"))`. Green in CT.
- Criterion 6 — pass: `test_cli_modules_have_no_shell_launch` reads both module sources, asserts no `os:cmd`, no `open_port({spawn,` command-string form, no `sh -c`. Confirmed independently: `grep -nE "os:cmd|sh -c|open_port\(\{spawn," soma_run.erl soma_tool_call.erl` exits 1 (no match).
- Criterion 7 — pass: `kill_os_process/1` now resolves `kill` with `os:find_executable("kill")` and spawns `open_port({spawn_executable, Kill}, [{args, ["-KILL", integer_to_list(OsPid)]}, ...])`, replacing the `os:cmd("kill -KILL " ++ ...)` from #19. `wait_kill_done/1` drains the port so its `exit_status` never leaks into the run mailbox. The unchanged #19 lifecycle suite (`soma_cli_lifecycle_SUITE`, 6 cases incl. external-process-dead-after-timeout and -after-cancel) stays green in CT.
- Criterion 8 — pass: `docs/tool-manifest.md` section "CLI adapter defaults: environment and working directory" states the minimal-env policy (PATH only, other vars absent) and the fixed-cwd policy (adapter-chosen directory, not the runtime cwd). `test_manifest_doc_states_env_and_cwd_defaults` pins both.
- Criterion 9 — pass: `rebar3 ct` reports "All 59 tests passed" and `rebar3 eunit` reports "48 tests, 0 failures" under the new env/cwd defaults; the #18 happy path and #19 lifecycle suites run with `#!/bin/sh` helpers finding their programs through the retained PATH.

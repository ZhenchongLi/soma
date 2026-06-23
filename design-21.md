# [cc] v0.2: give cli adapter a minimal env, fixed cwd, and shell-safety pins

## Current state

The cli adapter launches external programs without a shell. `soma_tool_call:run_cli/5`
builds `Args = [render_arg(A) || A <- Argv] ++ [render_input(Input)]` and calls
`open_port({spawn_executable, Executable}, [{args, Args}, exit_status, binary,
use_stdio, stderr_to_stdout])`. Each argv element reaches the child as one literal
argument, so `$(...)`, `>`, `;`, and `$HOME` already pass through unexpanded. The
suite `soma_cli_adapter_SUITE:test_cli_argv_metacharacter_is_literal` already pins
the `$(...)` case.

Three gaps remain.

The port options carry no `{env, ...}`. The child inherits the runtime's whole
environment, so any variable set in the BEAM's environment is visible to the
external program.

The port options carry no `{cd, ...}`. The child runs in whatever directory the
runtime process happens to sit in, not a directory the adapter controls.

The timeout/cancel teardown added in #19 kills the external process with a shell.
`soma_run:kill_os_process/1` runs `os:cmd("kill -KILL " ++ integer_to_list(OsPid))`,
and `os:cmd/1` runs its string through `/bin/sh -c`. That is a shell command string
in the core, the exact thing `docs/design.md:324-331` says the runtime must not use.
It is the only `os:cmd` in `soma_run` or `soma_tool_call`; the launch path itself is
already shell-free.

## Approach

Set a minimal environment on the launch port. `open_port`'s `{env, _}` option is
additive over the inherited environment, so a minimal env means clearing the
variables we do not want and keeping a small allowed set. We pass an env that unsets
everything by inheriting nothing extra and keeps `PATH`. Concretely the adapter
builds the env list so the child sees `PATH` (taken from the runtime's own `PATH` so
a `#!/bin/sh` helper can still find `printf`, `tr`, `sleep`, `touch`) and does not
see other named runtime variables. A variable the test sets in the runtime
environment but that is not on the allowed list must be absent in the child. The
allowed set for v0.1 is just `PATH`; that is the smallest set that still lets the
existing `#!/bin/sh` test helpers run.

Set a fixed working directory on the launch port. The adapter chooses a stable
directory that is not the runtime process cwd and passes it as `{cd, Dir}`. A
system temp directory works: it exists, it is writable, and it is not where the
BEAM was started. The child's reported cwd is that directory, not the runtime's.
This is an adapter-level default, not a manifest field — per-tool cwd is out of
scope for this issue.

Replace the shell kill with an executable-plus-args kill. `kill_os_process/1`
resolves the `kill` program with `os:find_executable("kill")` and runs it through a
port: `open_port({spawn_executable, Kill}, [{args, ["-KILL", integer_to_list(Pid)]}])`.
The pid is a BEAM-produced integer, so there is no interpolation surface, and there
is no shell on the path. After this change neither `soma_run` nor `soma_tool_call`
contains `os:cmd`, an `open_port` `{spawn, _}` command-string form, or a `sh -c`
invocation.

The env, cwd, and kill changes live entirely in `soma_tool_call:open_cli_port/2`
(env + cwd on the launch port) and `soma_run:kill_os_process/1` (shell-free kill).
The descriptor shape, the worker reply protocol, and the `soma_run` state machine do
not change. `docs/tool-manifest.md` gains a short section stating the two adapter
defaults so the policy is written down.

Criteria 3, 4, and 5 pin behaviour the no-shell launch already has. They are
regression pins. The Dev writes them staged-red: assert the shell-expanded value
first, watch the test fail, then correct the expected value to the literal. Criterion
7 is the genuinely new kill-path work; criteria 1 and 2 are new env/cwd work.

## Acceptance criteria → tests

New tests for criteria 1, 2, 3, 4, 5 land in `soma_cli_adapter_SUITE`. The env, cwd,
`>`, `;`, and `$HOME` checks each need a helper that reports an observable fact about
the child (its environment, its cwd, or one literal argv element), so each follows
the existing pattern of writing a small `#!/bin/sh` helper, running a one-step cli
run through the live session, and reading the recorded step output. Criterion 6 is a
source-file read of both modules. Criterion 7 reuses the #19 lifecycle suite, with a
new source-read pin for the shell-free kill path. Criterion 8 is the existing
suites staying green; criterion 9 is the manifest doc.

### Criterion 1 — child does not see a runtime env var the adapter did not pass
- Call chain: `soma_agent_session:start_run` → `soma_run` `executing` → `start_tool_call` → `soma_tool_call:start` → `run_cli` → `open_cli_port` → `open_port({spawn_executable, ...}, [{env, ...}, ...])`
- Test entry: `soma_agent_session:start_run` (full session/run/tool-call chain, no layer bypassed). The test sets a marker variable in the runtime environment with `os:putenv/2`, registers a helper that prints that variable's value, runs the step, and asserts the recorded output is empty.
- Test: `test_cli_child_env_omits_runtime_var` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 2 — child runs in the adapter's directory, not the runtime cwd
- Call chain: `soma_agent_session:start_run` → `soma_run` `executing` → `start_tool_call` → `soma_tool_call:start` → `run_cli` → `open_cli_port` → `open_port({spawn_executable, ...}, [{cd, Dir}, ...])`
- Test entry: `soma_agent_session:start_run` (full chain). A helper prints its own working directory (`pwd`). The test reads the runtime's cwd with `file:get_cwd/0`, runs the step, and asserts the recorded output is the adapter's directory and is not the runtime cwd.
- Test: `test_cli_child_cwd_is_adapter_dir` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 3 — `>` plus a filename writes no file and reaches the child literally
- Call chain: `soma_agent_session:start_run` → `soma_run` `executing` → `start_tool_call` → `soma_tool_call:start` → `run_cli` → `open_cli_port` → port spawn with separate argv
- Test entry: `soma_agent_session:start_run` (full chain). The argv carries `">"` and a target filename. A helper echoes its argv. The test asserts the recorded output contains the literal `>` and the target filename, and that no file exists at that path. Staged-red: first assert the file exists, see it fail, then flip to absence.
- Test: `test_cli_argv_redirect_is_literal` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 4 — `;` plus a second word runs no second program and reaches the child literally
- Call chain: `soma_agent_session:start_run` → `soma_run` `executing` → `start_tool_call` → `soma_tool_call:start` → `run_cli` → `open_cli_port` → port spawn with separate argv
- Test entry: `soma_agent_session:start_run` (full chain). The argv carries `";"` and a second word that, under a shell, would name a program with an observable side effect. A helper echoes its argv. The test asserts the recorded output contains the literal `;` and the second word, and that the side effect did not happen. Staged-red: first assert the second program ran, see it fail, then flip.
- Test: `test_cli_argv_semicolon_is_literal` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 5 — `$HOME` reaches the child as literal text, not the runtime's HOME
- Call chain: `soma_agent_session:start_run` → `soma_run` `executing` → `start_tool_call` → `soma_tool_call:start` → `run_cli` → `open_cli_port` → port spawn with separate argv
- Test entry: `soma_agent_session:start_run` (full chain). The argv carries `"$HOME"`. A helper echoes its first argv argument. The test asserts the recorded output is exactly the four characters `$HOME`, and is not the runtime's `HOME` value read with `os:getenv("HOME")`. Staged-red: first assert it equals the runtime HOME, see it fail, then flip to the literal.
- Test: `test_cli_argv_home_is_literal` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 6 — neither module has a shell launch path
- Call chain: none (direct source-file read)
- Test entry: off the call chain, because the criterion is about source text, not runtime behaviour — a shell-free runtime could still gain a shell call in a future edit, so the pin reads the module source. The test reads `soma_tool_call.erl` and `soma_run.erl` and asserts neither contains `os:cmd`, an `open_port` `{spawn,` command-string form, or `sh -c`.
- Test: `test_cli_modules_have_no_shell_launch` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 7 — timeout/cancel teardown kills the external process without a shell
- Call chain (kill is shell-free): `soma_run` `waiting_tool` `state_timeout`/`info cancel` → `kill_os_process` → `os:find_executable("kill")` → `open_port({spawn_executable, Kill}, [{args, ["-KILL", Pid]}])`
- Test entry: two layers. The shell-free property is a source-read pin on `soma_run.erl` (`kill_os_process` uses `spawn_executable`, no `os:cmd`). The external-process-is-gone property is the existing #19 lifecycle suite, entered at `soma_agent_session:start_run`, driven to `timeout` and to `cancelled`, asserting the marker file is absent. The source pin is off the runtime chain for the same reason as criterion 6.
- Test: `test_cli_kill_path_has_no_shell` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`, plus the unchanged `test_cli_external_process_dead_after_timeout` and `test_cli_external_process_dead_after_cancel` in `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`

### Criterion 8 — existing suites stay green under the new env/cwd defaults
- Call chain: `soma_agent_session:start_run` → `soma_run` → `soma_tool_call` for the cli suites; the in-BEAM suites run their existing chains unchanged
- Test entry: the full existing suites run as-is. The #18 happy path and the #19 lifecycle suite must still pass, which means the minimal env must keep a usable `PATH` so each `#!/bin/sh` helper finds `printf`, `tr`, `sleep`, and `touch`.
- Test: the existing `soma_cli_adapter_SUITE`, `soma_cli_lifecycle_SUITE`, `soma_cli_failure_SUITE`, `soma_run_happy_path_SUITE`, and `soma_run_failure_SUITE` stay green under `rebar3 eunit && rebar3 ct`

### Criterion 9 — manifest doc states the env and cwd defaults
- Call chain: none (direct source-file read)
- Test entry: off any runtime chain — the deliverable is documentation. `docs/tool-manifest.md` gains a section stating the default environment policy (minimal env, `PATH` only) and the default working-directory policy (an adapter-chosen stable directory, not the runtime cwd) for cli tools.
- Test: none (doc change, reviewed by reading `docs/tool-manifest.md`)

## Risks & trade-offs

Keeping only `PATH` is a real bet that no current helper needs another variable.
The #18 and #19 helpers are plain `#!/bin/sh` scripts calling `printf`, `tr`,
`sleep`, and `touch`, all found through `PATH`, so the bet holds for v0.1. If a
later cli tool needs `HOME` or `LANG`, it has to wait for the per-tool env override
that this issue lists as out of scope.

Using a system temp directory as the fixed cwd means the child can write there. That
is wider than a per-run scratch directory, but narrowing it to a per-run directory is
cwd policy work this issue does not take on. The criterion only asks that the cwd be
adapter-set and not the runtime cwd, and a temp directory meets that.

The shell-free kill resolves `kill` with `os:find_executable/1`. If `kill` is not on
`PATH`, the resolve returns `false` and the teardown cannot signal the child. On the
Linux release targets `kill` is present, so this matches the existing assumption; the
kill path should treat a `false` resolve as a no-op rather than crash the run.

`os:find_executable/1` reads the runtime's `PATH`, which is a different `PATH` from
the minimal one the child gets — that is intended. The kill runs in the runtime's
context, not the child's, so it uses the runtime's `PATH` to find `kill`.

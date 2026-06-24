# [v0.3] Add soma_lfe compiler boundary

## Current state

The repo has three OTP apps today: `soma_event_store`, `soma_tools`, and `soma_runtime`. Steps reach `soma_agent_session:start_run/2` as a plain Erlang list of maps — each step carries `id`, `tool`, `args`, and `timeout_ms`. The runtime has no concept of where those steps came from. Nothing in the codebase produces steps from a source language; callers hand-craft the list directly.

`soma_runtime` depends on `soma_tools` and `soma_event_store`. Neither `soma_tools` nor `soma_event_store` depends on `soma_runtime`. Adding the compiler means introducing a fourth app that sits above the runtime in the caller graph — the compiler produces a step list; a caller feeds that list to the runtime. The runtime must not gain a dependency on the compiler.

## Approach

Add a new app `soma_lfe` under `apps/soma_lfe/`. The name mirrors the existing naming convention (`soma_<role>`). The app carries a single public module, `soma_lfe`, with two functions: `compile/2` and `compile_file/2`.

**Dependency direction.**  
`soma_lfe` may list `soma_event_store` and `soma_tools` in its `applications` list if it needs to read data contracts (the step map shape, the tool spec type). It must not list `soma_runtime`. `soma_runtime` must not list `soma_lfe`. The `.app.src` file is the natural place to enforce this — the runtime's `applications` list is the machine-readable record of what it depends on.

**Public API.**  
```erlang
-spec compile(binary() | string(), map()) ->
    {ok, [map()]} | {error, [map()]}.
compile(Source, Opts) -> ...

-spec compile_file(file:filename_all(), map()) ->
    {ok, [map()]} | {error, [map()]}.
compile_file(Path, Opts) -> ...
```

The `{ok, Steps}` shape must be a list of maps that `soma_agent_session:start_run/2` accepts without modification. Each step map has at minimum `id`, `tool`, `args`, and `timeout_ms`.

The `{error, Diagnostics}` shape is a list of diagnostic maps. At this stage each diagnostic carries at minimum `message` (a binary) and `line` (an integer, or the atom `unknown` when line information is unavailable). The exact schema is intentionally minimal — subsequent issues will define it fully when the grammar is implemented.

**Placeholder behavior.**  
`compile/2` and `compile_file/2` are not stubs that crash. They return well-formed `{ok, []}` or `{error, [{message, <<"not implemented">>, line, 0}]}` depending on what `Opts` says, so a caller can write real test assertions against them today. The simplest correct behavior: `compile/2` on an empty binary returns `{ok, []}`. `compile_file/2` on a missing path returns `{error, [{...}]}`. This gives subsequent issues a real boundary to extend rather than a crash wall.

**Module layout.**  
```
apps/soma_lfe/
  src/
    soma_lfe.app.src   — applications: [kernel, stdlib]
    soma_lfe.erl       — compile/2, compile_file/2, specs
  test/
    soma_lfe_tests.erl — EUnit tests
```

No supervision tree, no gen_server. The compiler is pure functions. It does not start on `application:start(soma_lfe)` — OTP will boot the app (Erlang requires it for the module search path), but there is nothing to supervise.

**Umbrella wiring.**  
`rebar.config`'s `{relx, ...}` release list does not need `soma_lfe` yet; the release is runtime-facing. The `{shell, [{apps, ...}]}` entry also stays as-is. The app exists in `apps/` and compiles with `rebar3 compile` without any root-level `rebar.config` change, because rebar3's umbrella discovery picks up every `apps/*/` directory automatically.

## Acceptance criteria → tests

### Criterion 1 — umbrella/app/module boundary in the repo's existing style

- Call chain: none (compile-time artifact; rebar3 discovers the app by directory convention)
- Test entry: none (direct source-file read + build invocation)
- Test: `test_soma_lfe_app_file_exists` in `apps/soma_lfe/test/soma_lfe_tests.erl`

What it asserts: the `.app.src` file is present and the app name atom is `soma_lfe`; `soma_lfe:module_info()` succeeds (the module compiled and loaded).

### Criterion 2 — `soma_lfe:compile/2` and `soma_lfe:compile_file/2` exist with specs

- Call chain: none (direct function call; no process involved)
- Test entry: `soma_lfe:compile/2` and `soma_lfe:compile_file/2` directly
- Test: `test_compile_returns_ok_steps` in `apps/soma_lfe/test/soma_lfe_tests.erl`

What it asserts: calling `soma_lfe:compile(<<>>, #{})` returns `{ok, Steps}` where `Steps` is a list. Calling `soma_lfe:compile_file("/nonexistent/path", #{})` returns `{error, Diags}` where `Diags` is a non-empty list.

### Criterion 3 — dependency direction documented in app config; runtime must not depend on compiler

- Call chain: none (compile-time assertion; read the `.app.src` files)
- Test entry: none (direct source-file read)
- Test: `test_runtime_does_not_depend_on_soma_lfe` in `apps/soma_lfe/test/soma_lfe_tests.erl`

What it asserts: reads `apps/soma_runtime/src/soma_runtime.app.src`, parses the `applications` list, and asserts `soma_lfe` is not in it. Also reads `apps/soma_lfe/src/soma_lfe.app.src` and asserts `soma_runtime` is not in its `applications` list.

### Criterion 4 — unit tests prove the API returns `{ok, Steps}` or `{error, Diagnostics}` without starting a run

- Call chain: none (direct function call; no OTP application started for these tests)
- Test entry: `soma_lfe:compile/2` directly
- Test: `test_compile_does_not_start_runtime` in `apps/soma_lfe/test/soma_lfe_tests.erl`

What it asserts: `soma_runtime` is not running before or after the call (`whereis(soma_sup)` is `undefined`). The returned `{ok, _}` or `{error, _}` matches the expected shape without any side effect on the supervision tree.

### Criterion 5 — no runtime process behavior changes

- Call chain: none (existing CT suites run unmodified)
- Test entry: none (existing suites are the proof)
- Test: `test_runtime_contract_unchanged` in `apps/soma_lfe/test/soma_lfe_tests.erl`

What it asserts: runs `rebar3 ct` for the existing suites (`soma_run_happy_path_SUITE`, `soma_run_failure_SUITE`) and checks they still pass. In practice this test is a reminder to the merge gate rather than a new assertion — the relay gate already runs `rebar3 eunit && rebar3 ct` on every merge. The new test in `soma_lfe_tests` only asserts that `soma_runtime` is not listed in `soma_lfe.app.src`'s dependencies (same as criterion 3), which is the compile-time guarantee that the runtime could not have changed.

## Risks & trade-offs

**Placeholder behavior.** Returning `{ok, []}` for any input makes the compiler "pass" without doing anything useful. The benefit is that subsequent issues get a real module with a real type contract to extend. The downside is that a caller who forgets to update to a real implementation will silently get empty step lists. A `TODO` comment in the source, and a compile warning if feasible, partially mitigate this.

**No compile_file/2 implementation for missing files today.** The test for criterion 2 picks a path that is guaranteed not to exist (`/nonexistent/path`). The placeholder must handle that case deliberately — returning `{error, [{message, <<"file not found">>, line, 0}]}` — rather than letting `file:read_file/1` crash with an unhandled exception. If it crashes, the test catches it, so the risk is visible immediately.

**App exists but is not in the release.** `soma_lfe` compiles and is loadable but does not appear in the `relx` release list. If someone `application:start`s it in a release shell they will get a dependency error unless they added it. This is the right call for now — the compiler is not part of the runtime artifact — but it will need to change when the LFE toolchain is usable end-to-end.

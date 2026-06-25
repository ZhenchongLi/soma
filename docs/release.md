# Release packaging

Soma ships as a self-contained OTP release: a tarball that bundles the runtime
core apps, `sasl`, and the Erlang runtime (ERTS) itself, so it runs on a machine
with **no Erlang installed**.

## Bundled apps

The relx release in `rebar.config` is the **execution core**. It bundles exactly
these apps (the same set, in the same order, as the `{release, {soma, ...}, [...]}`
list in `rebar.config`):

- `soma_event_store`
- `soma_tools`
- `soma_runtime`
- `soma_actor`
- `sasl`

The release boots the runtime core — `soma_runtime` and its supervision tree.
`soma_actor` (the v0.4 agent-entity layer) is bundled too: it ships in the
release and the embedding application starts actors on top of the runtime.

The release is built per host architecture: building on macOS arm64 yields a
macOS arm64 artifact, building on Linux x86_64 yields a Linux x86_64 artifact,
and so on. The `prod` profile in `rebar.config` (`dev_mode=false`,
`include_erts=true`) is what makes the artifact self-contained.

## Build (current host architecture)

```bash
rebar3 as prod tar
```

Produces:

```
_build/prod/rel/soma/soma-0.1.0.tar.gz   # the distributable, ~13 MB
_build/prod/rel/soma/                     # the same release, assembled in place
```

The tarball unpacks to `bin/`, `erts-<vsn>/`, `lib/`, and `releases/`.

## Run

Extract anywhere and start it. The release boots the supervision tree and starts
`soma_runtime` automatically.

```bash
tar xzf soma-0.1.0.tar.gz -C /opt/soma
/opt/soma/bin/soma console      # interactive shell with the runtime started
/opt/soma/bin/soma foreground   # run in the foreground (e.g. under a supervisor)
```

## Enabling event persistence

By default the runtime's event store is **in-memory**: events are queryable while
the node is up, but a restart loses them. To make the store **durable** — so
events survive a node restart by being appended to an on-disk `disk_log` and
replayed on boot — set the `soma_runtime` application environment variable
`event_store_log` to a log file path **before** the runtime starts. When
`event_store_log` is set, `soma_sup` starts its `soma_event_store` child against
that path instead of the in-memory store; when it is unset, the store stays
in-memory and writes nothing to disk.

The release reads application environment from `sys.config`. Point
`event_store_log` at a writable path (the directory must exist and be writable by
the user running the node) with a `sys.config` such as:

```erlang
[
  {soma_runtime, [{event_store_log, "/var/lib/soma/events.log"}]}
].
```

Start the release with that config so persistence is enabled from boot:

```bash
/opt/soma/bin/soma console -config /path/to/sys.config
```

Leave `event_store_log` unset (omit it from `sys.config`) to keep the default
in-memory store.

## Smoke test

Boot the packaged release, drive one run end to end, and confirm it completes —
no Erlang toolchain required, only the unpacked release:

```bash
printf '%s\n' \
  '{ok,S}=soma_agent_session:start_link(#{}), {ok,_}=soma_agent_session:start_run(S,[#{id=>e,tool=>echo,args=>#{value=><<"smoke">>}}]), timer:sleep(300), io:format("~nSMOKE ~p alive=~p~n",[soma_agent_session:get_status(S), is_process_alive(S)]).' \
  'init:stop().' | _build/prod/rel/soma/bin/soma console
```

Expect the run to show `completed` and `alive=true`.

### Actor boot smoke test

The release also bundles `soma_actor` (the v0.4 agent-entity layer). To confirm
the actor layer boots and runs a task end to end, start an actor with
`soma_actor_sup:start_actor/1` against the booted runtime's event store, send a
one-step `echo` task, and poll `soma_actor:get_task_status/2` until it reads
`completed` — modeled on the session smoke test above, no Erlang toolchain
required:

```bash
printf '%s\n' \
  '{soma_event_store,Store,_,_}=lists:keyfind(soma_event_store,1,supervisor:which_children(soma_sup)), {ok,A}=soma_actor_sup:start_actor(#{actor_id=><<"smoke">>,model_config=>#{},tool_policy=>#{},event_store=>Store}), T=(<<"smoke-task">>), {ok,T}=soma_actor:send(A,#{type=><<"chat">>,payload=>#{text=><<"hi">>},task_id=>T,steps=>[#{id=>s1,tool=>echo,args=>#{value=><<"smoke">>}}]), timer:sleep(300), io:format("~nACTOR-SMOKE ~p alive=~p~n",[soma_actor:get_task_status(A,T), is_process_alive(A)]).' \
  'init:stop().' | _build/prod/rel/soma/bin/soma console
```

Expect the task status to show `completed` and `alive=true`.

### macOS note

On macOS the `daemon` / `ping` / `stop` control commands are unreliable — they
depend on connecting to the node over Erlang distribution, which trips on
hostname resolution locally. The node itself boots fine (it registers with epmd);
only the external control path is flaky. Use `console` / `foreground` to run and
smoke-test on macOS. On Linux the control commands work normally.

## Packaged CLI helpers

A tool's external CLI helper ships inside the release as part of the
`soma_tools` app's `priv` directory. Standard rebar3/relx packaging copies
`apps/soma_tools/priv` into the release tree, so in an unpacked release a
packaged helper lives at a release-relative path under

```
lib/soma_tools-<vsn>/priv/...
```

For the committed sample helper the full release-relative location is
`lib/soma_tools-<vsn>/priv/cli/soma_sample_upper` (with `<vsn>` the `soma_tools`
app version, e.g. `lib/soma_tools-0.1.0/priv/cli/soma_sample_upper`).

To confirm the helper actually shipped, run it directly out of the unpacked
release — no Erlang toolchain, just the packaged binary. It uppercases its last
argv argument (it does not read stdin):

```bash
_build/prod/rel/soma/lib/soma_tools-0.1.0/priv/cli/soma_sample_upper hello
```

Expect it to print `HELLO`. Substitute the `soma_tools` version in
`soma_tools-<vsn>` to match the release you unpacked.

### Naming the executable: `code:priv_dir/1`, not an absolute build path

A tool **names its packaged executable by a release-relative path**, not by the
absolute filesystem location it happened to be built at. At registration the
tool declares only the path relative to its app's `priv` directory (here
`cli/soma_sample_upper`); it does **not** bake in an absolute build path such as
`/Users/.../_build/prod/.../priv/cli/soma_sample_upper`. That absolute path is
correct only on the build host and is wrong in any unpacked release.

The release-relative name is resolved to a concrete file at invocation time with
`code:priv_dir/1`: the tool calls `code:priv_dir(soma_tools)` to get the
loaded app's `priv` directory — which is `lib/soma_tools-<vsn>/priv` inside an
unpacked release — and joins its declared `cli/...` suffix onto it. Because
`code:priv_dir/1` reports wherever the app is actually loaded from, the same
registered name works in the build tree and in every relocated release without
any absolute path being baked in.

## Per-architecture CLI helpers

An external CLI executable is a native binary, so it is **packaged separately
for each target architecture**. Soma's three packaging targets are macOS arm64,
Linux x86_64, and Linux arm64, and each gets its own helper build.

A release is built on the host whose architecture it targets, and a build on one
architecture carries **only that architecture's helper** — the macOS arm64
release bundles the macOS arm64 binary, the Linux x86_64 release bundles the
Linux x86_64 binary, and the Linux arm64 release bundles the Linux arm64 binary.
No single tarball carries helpers for more than its own architecture; you cannot
relocate a packaged helper to a different architecture's release.

## Linux x86_64 / arm64 artifacts

Build the same `prod` profile on each Linux target (a Linux container or CI
runner per architecture); each produces its own self-contained tarball. Those
artifacts are not produced by this macOS checkout — they are tracked separately.

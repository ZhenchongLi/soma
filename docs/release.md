# Release packaging

Soma ships as a self-contained OTP release: a tarball that bundles the three
apps (`soma_runtime`, `soma_tools`, `soma_event_store`), `sasl`, and the Erlang
runtime (ERTS) itself, so it runs on a machine with **no Erlang installed**.

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

## Smoke test

Boot the packaged release, drive one run end to end, and confirm it completes —
no Erlang toolchain required, only the unpacked release:

```bash
printf '%s\n' \
  '{ok,S}=soma_agent_session:start_link(#{}), {ok,_}=soma_agent_session:start_run(S,[#{id=>e,tool=>echo,args=>#{value=><<"smoke">>}}]), timer:sleep(300), io:format("~nSMOKE ~p alive=~p~n",[soma_agent_session:get_status(S), is_process_alive(S)]).' \
  'init:stop().' | _build/prod/rel/soma/bin/soma console
```

Expect the run to show `completed` and `alive=true`.

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
app version, e.g. `lib/soma_tools-0.1.0/priv/cli/soma_sample_upper`). A tool
never bakes in an absolute build path: it resolves the helper at runtime via
`code:priv_dir(soma_tools)` and joins the relative path `cli/...`, which returns
this `lib/soma_tools-<vsn>/priv` directory wherever the app is loaded from.

## Linux x86_64 / arm64 artifacts

Build the same `prod` profile on each Linux target (a Linux container or CI
runner per architecture); each produces its own self-contained tarball. Those
artifacts are not produced by this macOS checkout — they are tracked separately.

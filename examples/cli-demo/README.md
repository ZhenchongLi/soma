# soma CLI tour

A guided, screen-recordable walk through the soma daemon over the packaged
`soma` command. Every beat is a real CLI call — nothing is staged.

The thesis it shows: **an agent run on soma is a supervised OTP process tree, not
a while-loop.** So you can run a task, *cancel a live one for real*, watch a
crashing tool fail without taking the daemon down, replay the whole thing as an
audit trace, and ask a real model — all through one small CLI over a local
socket.

## Run it

From the repo root, build the release once (the dev tree may already have it):

```sh
rebar3 release
```

Then:

```sh
examples/cli-demo/demo.sh            # interactive — pauses between beats
NO_PAUSE=1 examples/cli-demo/demo.sh # straight through
```

The script finds `_build/default/rel/somad/bin/soma` automatically (or a `soma`
on your `PATH`). The first call **auto-starts the daemon** — there's no separate
"start the server" step.

## The five beats

| # | Command | What it proves |
|---|---------|----------------|
| 1 | `soma run pipeline.lfe` | A 3-step task (`file_read → echo → file_write`) runs in order; each step gets its own supervised tool-call process. |
| 2 | `soma run slow.lfe --detach` → `soma cancel <task>` | Cancellation is real — a live 60s task is stopped mid-flight; the daemon stays up. |
| 3 | `soma run crash.lfe` then `soma run pipeline.lfe` | A crashing tool fails *its* run as data; the daemon keeps serving the next one. Isolation by process boundary, not `try/catch`. |
| 4 | `soma trace <correlation-id>` | The whole run replayed as Lisp events — including a distinct `tool-call-pid` per step. |
| 5 | `soma ask "..."` | The agent path: intent → model → answer. Needs a model configured (below). |

The same Lisp you write task files in is what comes back on the wire — no JSON
anywhere. `soma run` takes a `task-id` + `correlation-id`; `status`/`cancel` use
the `task-id`, `trace` uses the `correlation-id`.

## Enabling beat 5 (`soma ask`)

`soma run` needs no model. `soma ask` does. The provider lives **at the daemon**,
never on the wire — and the API key only ever comes from an env var, never a file:

```sh
cp examples/cli-demo/config.example ~/.soma/config   # edit base_url/model if needed
export SOMA_LLM_API_KEY="<your key>"                 # the daemon reads this from its env
soma stop                                            # so the daemon reloads config on next call
```

The shipped `config.example` points at the validated SophNet endpoint
(`openai_compat`, `DeepSeek-V3`). The daemon reads `~/.soma/config` **once, at
boot**, so after editing it you must `soma stop` (the next client call auto-starts
a fresh daemon that picks up the change). `SOMA_LLM_API_KEY` must be exported in
the shell that triggers that auto-start.

## The task files

All seven built-in tools the daemon seeds are fair game (`echo`, `sleep`, `fail`,
`file_read`, `file_write`, `text_grep`, `text_head`). The tour uses:

- **`pipeline.lfe`** — read a file, pass it through echo, write it back out.
- **`slow.lfe`** — one 60s `sleep` step, for the cancel beat.
- **`crash.lfe`** — the `fail` tool in `crash` mode, for the isolation beat.
- **`timeout.lfe`** — a 3s sleep with a 500ms step budget. Not in the scripted
  arc; run it by hand to watch a hung step get timed out:
  `soma run examples/cli-demo/timeout.lfe`.

Task files are Soma Lisp s-exprs (`(task (let* ((id (tool name ...))) (return id)))`).
Note the LFE reader has **no `;` comments** — keep these files comment-free.

## Want the "external process actually dies" version?

The cancel beat here uses the in-BEAM `sleep` tool, so "the worker is killed" is
the proof. To see soma kill a real external OS process on cancel, run the
Erlang-shell demo instead:

```sh
rebar3 shell
1> c("examples/soma_demo").
2> soma_demo:demo3().   % registers a cli `sleep 30` helper, cancels it, shows the OS pid is gone
```

`examples/soma_demo.erl` and `examples/soma_actor_demo.erl` drive the runtime and
the actor layer directly, below the CLI.

## Cleanup

```sh
soma stop          # stop the daemon
rm -rf /tmp/soma-demo
```

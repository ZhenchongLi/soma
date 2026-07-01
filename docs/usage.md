# Soma User Manual

This guide is for using Soma from the packaged `soma` command: running workflow
files, asking a configured model, checking task status, cancelling work, and
reading traces. For architecture and implementation boundaries, see
[`README.md`](../README.md). For the full CLI protocol reference, see
[`cli.md`](cli.md). For workflow syntax details, see [`lfe-dsl.md`](lfe-dsl.md).

## Get The Command

From an installed release, put the release `bin/` directory on your `PATH` and
run `soma` directly.

From this checkout:

```bash
rebar3 release
SOMA="_build/default/rel/somad/bin/soma"
```

There are two executables in the release:

| Command | Use |
| --- | --- |
| `soma` | User task command: `run`, `ask`, `status`, `trace`, `cancel`, `stop`, `daemon`. |
| `somad` | OTP node-control script: `console`, `foreground`, `daemon`, `stop`, `status`. |

Most users only need `soma`. Client commands auto-start the local daemon when it
is not already listening. You can run the daemon in the foreground when you want
to watch logs:

```bash
$SOMA daemon
```

Stop it with:

```bash
$SOMA stop
```

## Quick Start: Run A Workflow

Create a small file pipeline:

```bash
mkdir -p /tmp/soma-demo
printf 'hi soma\n' > /tmp/soma-demo/input.txt

cat > /tmp/soma-demo/pipeline.lisp <<'EOF'
(task
  (let* ((read (tool file_read
                 (path "input.txt")
                 (root "/tmp/soma-demo")))
         (process (tool echo
                    (from read)))
         (write (tool file_write
                  (path "output.txt")
                  (root "/tmp/soma-demo")
                  (bytes (from process)))))
    (return write)))
EOF

$SOMA run /tmp/soma-demo/pipeline.lisp
cat /tmp/soma-demo/output.txt
```

The command prints a Lisp `(result ...)` form. The important fields are:

```lisp
(result
  (status completed)
  (task-id "task-1")
  (outputs ...)
  (correlation-id "corr-2"))
```

Use the `task-id` for `status` and `cancel`. Use the `correlation-id` for
`trace`.

## Workflow Files

`soma run FILE` reads Soma Lisp source. Public static tasks use `(task ...)`;
`(run ...)` remains the compatibility/core run form. Steps run strictly in the
order they appear.

```lisp
(task
  (let* ((greet (tool echo
                  (value "hello")
                  (timeout-ms 5000))))
    (return greet)))
```

In `(task ...)`, each `let*` binding creates one step:

| Field | Meaning |
| --- | --- |
| Step id | A unique symbol inside this workflow, such as `greet` or `read`. |
| Tool name | A registered tool, such as `echo`, `sleep`, `file_read`, or `file_write`. |
| Tool arguments | Input for the tool. Omit them for empty input. |
| `(timeout-ms N)` | Optional per-step wall-clock budget. If it expires, the run times out and the active worker is stopped. |

Internally, after the workflow is compiled, each step is a map with `id` and `tool`;
the runtime rejects a bad step before starting the run. Duplicate step ids are
not useful because later references need a single prior output, so keep ids
unique.

### Pass Data Between Steps

Use a previous step's whole output as the next step's input:

```lisp
(process (tool echo
           (from read)))
```

Use a previous step's output as one field:

```lisp
(write (tool file_write
         (path "output.txt")
         (root "/tmp/soma-demo")
         (bytes (from process))))
```

`from` can only point to an earlier binding in the same task. Unknown or forward
references are compile errors.

### Run From Stdin

Use `-` as the workflow path:

```bash
printf '(run (step greet echo (args (value "hello"))))\n' | $SOMA run -
```

## Built-In Tools

The local daemon seeds these tools automatically:

| Tool | Use |
| --- | --- |
| `echo` | Return the input as output. Useful for simple transforms and demos. |
| `sleep` | Wait for a number of milliseconds. Useful for timeout and cancellation tests. |
| `fail` | Return or raise a controlled failure. Mostly useful for testing isolation. |
| `file_read` | Read a file under a supplied `root`. |
| `file_write` | Write bytes to a file under a supplied `root`. |

File tools use `(root "...")` as their sandbox root. Keep file paths relative to
that root:

```lisp
(step read file_read
  (args (root "/tmp/soma-demo") (path "input.txt")))
```

Operators can register additional in-BEAM or external CLI tools. Workflow users
still call them by tool name; workflows do not contain shell command strings.

## Manage Tasks

For short work, `soma run` waits and prints the final result. For long work, run
detached:

```bash
$SOMA run examples/cli-demo/slow.lfe --detach
```

Detached runs print an accepted handle:

```lisp
(accepted (task-id "task-3") (correlation-id "corr-4"))
```

Read status:

```bash
$SOMA status "task-3"
```

Common states:

| State | Meaning |
| --- | --- |
| `running` | Work is still active. |
| `completed` | The workflow finished successfully. |
| `failed` | A tool or task failed. The reply usually carries an error reason. |
| `timeout` | A step or model call exceeded its timeout. |
| `cancelled` | The task was cancelled. |
| `unknown` | The daemon does not know that task id. |

Cancel a live detached task:

```bash
$SOMA cancel "task-3"
```

Cancellation is real: Soma stops the active tool worker, and for external CLI
tools it also tears down the child OS process. Cancelling a task that is already
terminal is a no-op or returns a non-running result.

Synchronous runs are tied to the client connection. If a synchronous `soma run`
client disconnects while a tool is active, the daemon cancels that in-flight run.
Detached runs outlive the client and must be managed by task id.

## Tracing

Every task gets a correlation id. Use it to read the operational timeline:

```bash
$SOMA trace "corr-4"
```

The trace shows the task and run events in timestamp order: actor events, model
events when present, proposal events when present, run events, step events, and
tool events. It is the easiest way to answer "what happened to this task?"

For embedded/operator diagnostics, the same trace renderer is available below
the CLI:

```erlang
soma_trace:render(StorePid, CorrelationId).
```

## Ask The Model

`soma run` needs no model. `soma ask` uses the daemon's configured model:

```bash
$SOMA ask "summarize the build log"
```

Create `~/.soma/config`:

```toml
[llm]
provider = "openai_compat"
base_url = "https://api.openai.com/v1"
model = "gpt-4.1-mini"
# optional:
# enable_thinking = false
# max_tokens = 1024
```

Then export the API key in the environment that starts the daemon:

```bash
export SOMA_LLM_API_KEY="..."
$SOMA stop 2>/dev/null || true
$SOMA ask "say hello"
```

The daemon reads config at boot. After changing `~/.soma/config` or
`SOMA_LLM_API_KEY`, stop the daemon so the next client command starts a fresh one.

To use a different config file:

```bash
SOMA_CONFIG=/path/to/config SOMA_LLM_API_KEY="..." $SOMA daemon
```

Provider settings such as `base_url` and `model` live in config. Optional
provider fields `enable_thinking` and `max_tokens` are passed through when set.
The API key comes only from `SOMA_LLM_API_KEY`; do not put secrets in workflows
or config files. Soma events must not contain provider secrets.

### Ask With Policy And Budgets

`soma ask` can carry a tool allowlist and simple budgets. These are mainly useful
when a model is allowed to propose tool-running work:

```lisp
(ask
  (intent "summarize this")
  (allow echo file_read)
  (budget-llm 3)
  (budget-steps 5))
```

The packaged command builds the simple `(ask (intent "..."))` form for normal
text prompts. Custom clients can send the richer Lisp form over the local socket.

### Real Provider Smoke Test

The normal test gate never opens network sockets. To manually test the configured
OpenAI-compatible path from this checkout:

```bash
SOMA_LLM_API_KEY=sk-... rebar3 shell
```

```erlang
1> soma_llm_smoke:run().
```

The smoke module uses the same real provider path as `soma ask`: `openai_compat`
request shaping, `base_url` and `model` from config/defaults, and the API key
from `SOMA_LLM_API_KEY`.

### Advanced: actor with a real LLM provider

Most users should use `soma ask`. Embedded callers can start an actor whose
`model_config` carries `provider => openai_compat`; the prompt envelope must
include `llm => #{}` so the actor takes the LLM-call path:

```erlang
ModelConfig = #{
    provider => openai_compat,
    base_url => <<"https://api.openai.com/v1">>,
    model => <<"gpt-4.1-mini">>,
    api_key => list_to_binary(os:getenv("SOMA_LLM_API_KEY"))
},
{ok, Actor} = soma_actor_sup:start_actor(#{
    actor_id => <<"actor-real">>,
    model_config => ModelConfig,
    tool_policy => #{},
    event_store => Store
}),
Env = #{type => <<"chat">>,
        payload => #{prompt => <<"Say hello.">>},
        task_id => <<"t1">>,
        correlation_id => <<"c1">>,
        llm => #{}},
{ok, <<"t1">>} = soma_actor:send(Actor, Env).
```

This opens a real provider socket unless the config carries a fixed test
`response` seam. Use `soma_llm_smoke:run()` for the manual live smoke before
embedding this path.

### Advanced: stable-name actor addressing

`soma_actor_sup:start_actor/1` accepts an optional `stable_name` option — a
binary that names the actor in the actor registry:

```erlang
{ok, Actor} = soma_actor_sup:start_actor(#{
    actor_id => <<"actor-worker">>,
    stable_name => <<"worker">>,
    model_config => ModelConfig,
    tool_policy => #{},
    event_store => Store
}).
```

When the started actor's `init/1` sees a binary `stable_name`, it registers
itself under that name so other callers can address it by name instead of by
pid.

The binary-name registry is `soma_actor_registry`, a supervised worker started
under `soma_actor_sup`. It holds a `binary name => pid` map: an actor started
with a `stable_name` registers its pid there, and name-based lookups resolve
through it.

`soma_actor:send/2` accepts a binary stable name as its `ActorRef`, not just a
pid: when the first argument is a binary, `send/2` looks it up in
`soma_actor_registry` and delivers to the registered actor.

```erlang
{ok, <<"t2">>} = soma_actor:send(<<"worker">>, Env).
```

If the binary is an unknown stable name — no actor is registered under it —
`soma_actor:send/2` returns `{error, not_found}`.

```erlang
{error, not_found} = soma_actor:send(<<"no-such-name">>, Env).
```

## Reading events

Most users read events through:

```bash
$SOMA trace "corr-4"
```

The daemon records a mandatory event trail for each task and run. A typical
successful workflow includes:

```text
actor.message.received
actor.task.accepted
run.started
step.started
tool.started
tool.succeeded
step.succeeded
run.completed
actor.result.created
actor.task.completed
```

Failed, timed-out, cancelled, model, proposal, and resumed runs add their own
event types such as `run.failed`, `run.timeout`, `run.cancelled`,
`llm.started`, `proposal.approved`, and `run.resumed`.

By default the event store is in-memory, so events are available while the daemon
is running and disappear when the node stops. For a trail that survives a
restart, enable the durable `disk_log` store before the runtime starts.

In a release, set the `soma_runtime` application environment in `sys.config`:

```erlang
[
  {soma_runtime, [{event_store_log, "/var/lib/soma/events.log"}]}
].
```

Start the release with that config:

```bash
/opt/soma/bin/somad console -config /path/to/sys.config
```

When persistence is enabled, each event is appended to the on-disk `disk_log` and
also indexed in memory for reads. On restart, Soma replays the log and rebuilds
the in-memory index, so `trace`, status reconstruction, and event queries can see
the earlier durable trail.

Advanced embedding note: the lower-level event-store `start_link/1` form accepts
a log path option such as:

```erlang
soma_event_store:start_link(#{log => "/var/lib/soma/events.log"}).
```

That is the same opt-in durability mode: `log =>` selects an on-disk `disk_log`,
and replay on restart rebuilds the query index from the durable log.

At the packaged command surface, soma run FILE reads Soma Lisp source from
FILE and submits it through the same local Lisp wire.

The wire is length-prefixed Lisp s-expressions: public run requests use
`(task ...)`; `(run ...)` remains the compatibility/core run form. Other
requests are `(ask ...)`, `(status ...)`, `(trace ...)`, and `(cancel ...)`,
with `(result ...)`, `(accepted ...)`, `(status ...)`, or `(trace ...)` replies
rendered by `soma_lisp`. Detached run support is a `(detach)` marker inside
`(run ...)`; detached tasks live in `soma_cli_task_registry` and can be managed
by id.

## Common Failures

| Symptom | What to check |
| --- | --- |
| `unregistered_tool` | The workflow names a tool the daemon has not registered. Check spelling and installed tool manifests. |
| `timeout` | A step exceeded its `(timeout_ms N)` budget, or a model call exceeded its call timeout. Increase the budget or inspect the tool/model. |
| `failed` from `file_read` or `file_write` | Check `root`, relative `path`, permissions, and whether the parent directory exists. |
| `ask` fails before calling a model | Check `~/.soma/config`, `provider = "openai_compat"`, `base_url`, `model`, and `SOMA_LLM_API_KEY`. |
| `rejected` | The policy gate rejected a proposed tool or action. Check the allowlist. |
| `budget_exceeded` | The task hit `budget-llm` or `budget-steps` before completion. |
| `status unknown` | The task id is wrong, the daemon restarted without durable state, or the task belonged to another socket/daemon. |

When in doubt, use the `correlation-id` from the original reply:

```bash
$SOMA trace "corr-4"
```

## Examples

The repository includes a CLI tour:

```bash
rebar3 release
examples/cli-demo/demo.sh
```

Useful workflow files:

| File | What it shows |
| --- | --- |
| `examples/cli-demo/pipeline.lfe` | `file_read -> echo -> file_write`. |
| `examples/cli-demo/slow.lfe` | Long-running task for detach and cancel. |
| `examples/cli-demo/timeout.lfe` | A step timeout. |
| `examples/cli-demo/crash.lfe` | A controlled tool crash that fails the run without killing the daemon. |

## Next Docs

- [`cli.md`](cli.md) - exact command and Lisp wire reference.
- [`lfe-dsl.md`](lfe-dsl.md) - workflow language syntax and diagnostics.
- [`release.md`](release.md) - building, unpacking, and operating a release.
- [`tool-manifest.md`](tool-manifest.md) - registering additional tools.
- [`design.md`](design.md) - architecture and non-negotiable runtime boundaries.

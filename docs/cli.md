# Soma CLI

`soma` is the user command. It reads Soma Lisp task files, talks to the local Soma
daemon, and prints Lisp replies. Client commands auto-start the daemon when it is
not already listening.

The release also contains `somad`, the OTP node-control script. Use `soma` for
tasks; use `somad` only when you need release/node operations.

## Get The Command

From this checkout:

```bash
rebar3 release
SOMA="_build/default/rel/somad/bin/soma"
```

From an installed release, put the release `bin/` directory on `PATH` and run
`soma` directly.

## Commands

| Command | Use |
| --- | --- |
| `soma run FILE [--detach] [--socket PATH]` | Run Soma Lisp source from a file, or `-` for stdin. |
| `soma ask "INTENT" [--socket PATH]` | Ask the configured model through the daemon. |
| `soma status TASK_ID [--socket PATH]` | Read a task state. |
| `soma cancel TASK_ID [--socket PATH]` | Cancel a live detached run by task id. |
| `soma trace CORRELATION_ID [--socket PATH]` | Print the event trace for a correlation id. |
| `soma stop [--socket PATH]` | Stop the local daemon. |
| `soma daemon [--socket PATH]` | Run the daemon in the foreground. Usually optional. |

`--socket PATH` is mostly for tests or multiple local daemons. Without it, Soma
uses `$XDG_RUNTIME_DIR/soma.sock`, or `/tmp/soma-$USER.sock` when
`XDG_RUNTIME_DIR` is not set.

`--detach` is for `soma run`: it returns a task handle immediately and leaves the
run alive in the daemon.

## Run A Task

soma run FILE reads Soma Lisp source from FILE and sends it to the daemon.
Public static tasks use `(task ...)`; `(run ...)` remains the compatibility/core
run form. See [docs/lfe-dsl.md](lfe-dsl.md) for the language syntax.

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

`soma run` prints a `(result ...)` reply:

```lisp
(result
  (status completed)
  (task-id "task-1")
  (outputs ((read (value "hi soma\n")) ...))
  (correlation-id "corr-2"))
```

Exit code is `0` only when the reply contains `(status completed)`. Failed,
timed-out, or cancelled runs return non-zero and carry the reason in the printed
reply when one is available.

## Read From Stdin

Use `-` as the task source path:

```bash
printf '(task (let* ((greet (tool echo (value "hello")))) (return greet)))\n' | $SOMA run -
```

## Run In The Background

Detached runs return an accepted handle instead of waiting for the run to finish.

```bash
$SOMA run examples/cli-demo/slow.lfe --detach
```

Reply:

```lisp
(accepted (task-id "task-3") (correlation-id "corr-4"))
```

Use the ids from that reply:

```bash
$SOMA status "task-3"
$SOMA trace "corr-4"
$SOMA cancel "task-3"
```

`soma status <task-id>` prints:

```lisp
(status (state running))
(status (state completed))
(status (state failed))
(status (state timeout))
(status (state cancelled))
(status (state unknown))
```

`soma trace <correlation-id>` prints timestamp-ordered events:

```lisp
(trace
  (event (event-type "run.started") ...)
  (event (event-type "tool.started") ...)
  (event (event-type "run.completed") ...))
```

`soma cancel <task-id>` sends the daemon this request form:

```lisp
(cancel "task-3")
```

The reply is a `(result ...)` form, for example:

```lisp
(result (status cancelled) (task-id "task-3") (correlation-id "corr-4"))
```

## Ask The Model

`soma ask` sends an `(ask ...)` request to the daemon. The client never sends an
API key or provider settings; those live in the daemon config.

```bash
$SOMA ask "summarize the build log"
```

The minimal request is:

```lisp
(ask (intent "summarize the build log"))
```

The daemon also accepts allowlist and budget fields:

```lisp
(ask
  (intent "summarize the build log")
  (allow echo file_read)
  (budget-llm 3)
  (budget-steps 5))
```

A successful reply uses the same result shape as `run`; answer text is under
`(outputs ...)`:

```lisp
(result
  (status completed)
  (task-id "task-5")
  (outputs "the build failed during linking")
  (correlation-id "corr-6"))
```

Other common ask outcomes:

```lisp
(result (status rejected) (task-id "task-7") (error "...") (correlation-id "corr-8"))
(result (status failed) (task-id "task-9") (error (budget_exceeded max_llm_calls)) (correlation-id "corr-10"))
```

`rejected` means the policy gate refused the proposal. `budget_exceeded` means a
budget rejected the task before completion.

## Configure A Real Model

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

Then export the key in the environment that starts the daemon:

```bash
export SOMA_LLM_API_KEY="..."
$SOMA stop 2>/dev/null || true
$SOMA ask "say hello"
```

The next client command starts a daemon that reads the config. To use a different
config path:

```bash
SOMA_CONFIG=/path/to/config SOMA_LLM_API_KEY="..." $SOMA daemon
```

Provider modes:

- `mock-on-gate`: the normal test gate uses a mock model config and opens no
  network connection.
- `real-provider-by-config`: a real OpenAI-compatible provider is selected only
  by daemon config plus `SOMA_LLM_API_KEY`. Optional `enable_thinking` and
  `max_tokens` keys are passed through when present.

Real-provider `ask` returns text replies. Use `soma run` workflows for
deterministic tool work.

## Lisp Request Forms

These are the forms a custom client would send over the local socket:

```lisp
(task
  (let* ((greet (tool echo
                  (value "hello"))))
    (return greet)))

(run
  (step greet echo
    (args (value "hello"))))

(ask
  (intent "summarize this")
  (allow echo)
  (budget-llm 1)
  (budget-steps 3))

(trace "corr-4")
(status "task-3")
(cancel "task-3")
(stop)
```

Replies are also Lisp:

```lisp
(result (status completed) (task-id "task-1") (outputs ...) (correlation-id "corr-2"))
(accepted (task-id "task-3") (correlation-id "corr-4"))
(trace (event ...) (event ...))
(status (state completed))
(result (status stopped))
```

The transport carries one framed s-expression per request and one framed
s-expression per reply. No JSON is used on this path.

## Operational Notes

- The daemon is local and single-user. Socket file permissions are the boundary.
- `soma run` input is Soma Lisp source. `(task ...)` is the public static task
  form; `(run ...)` remains the compatibility/core run form. The same Lisp is
  the wire and the file format.
- Disconnecting a synchronous `soma run` client cancels that in-flight run.
- Detached runs outlive the client and can be read or cancelled by id.
- `soma stop` closes the listener, cancels live detached runs, and removes the
  socket file.

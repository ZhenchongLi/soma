# Soma CLI & daemon

> Status: the local daemon/server path is implemented as Erlang modules
> (`soma_cli`, `soma_cli_server`, `soma_cli_task_registry`) and proven through the
> test gate. The external shell command UX shown below is the intended product
> shape; today's relx `bin/soma` is still the OTP release control script
> (`console`, `foreground`, `daemon`, `status`, `stop`, and so on), not yet a
> task-client command parser.

## Scope: single-user, trusted, local

v1 targets **one user on one machine**: the daemon and every client run as the
same user, over a local Unix socket guarded by filesystem permissions. There is
**no cross-client authentication or isolation**, and none is needed — all clients
are *you* (your own Claude Code / Codex / shells). "Multiple clients share the
daemon" means your own trusted clients, not multi-tenant. (Multi-tenant — per-
client auth, namespaced stores, confined sandbox roots — is explicitly out of
scope; it would be a separate, later effort.)

This assumption is what makes the rest simple: a client-chosen `--root` is your
own filesystem; any of your shells managing any task by id is a feature, not a
risk.

## Purpose & positioning

Soma runs as a **long-lived background daemon** that your autonomous coding
agents (Claude Code, Codex) talk to through thin CLI commands. Soma is not
competing to *be* the agent — it is the **reliable execution substrate / sub-
agent** you delegate to: a supervised, cancellable, budget-gated, fully-audited
place to run multi-step work.

Supervision / trace / budget matter *more* when an autonomous agent drives than
when a human does: the caller needs execution it can trust (real timeout, real
cancel, crash isolation) and a trace it can inspect afterward. Soma has both —
and a daemon is where they pay off.

**Not MCP.** The caller has a shell; `soma run …` / `soma ask …` is enough. A
plain CLI over a local socket is leaner (no RPC surface to maintain) and
language-agnostic. (MCP could wrap the same daemon later if ever wanted.)

## Architecture — a daemon + thin clients over a Unix socket

```
  Claude Code ─┐
  Codex       ─┤  soma run / ask / trace   (thin client)
  your shell  ─┘            │
                            ▼  length-prefixed s-expr frames
            ┌──────────────────────────────────────┐
            │  $XDG_RUNTIME_DIR/soma.sock (AF_UNIX)  │  one rendezvous path,
            └──────────────────────────────────────┘  filesystem-perm guarded
                            │ accept → one handler process per connection
            ┌──────────────────────────────────────┐
            │  soma daemon (one BEAM)                │  long-lived
            │   soma_runtime + actors               │
            │   persistent (disk_log) event store   │  shared, one audit trail
            └──────────────────────────────────────┘
```

- **One daemon, your clients.** A listening Unix-domain socket serves many
  concurrent connections; the path is the rendezvous, each connection independent.
  In BEAM this is the idiomatic acceptor-loop + **one process per connection** —
  fitting soma's "process per unit of work": each request becomes an isolated
  `soma_actor` / `soma_run`.
- **Shared, durable state**: the supervised runtime, long-lived actors, and the
  persistent `disk_log` event store — alive across calls. Tasks **outlive the
  client that started them** (any of your shells can `soma status` / `soma cancel`
  by id later); all events land in **one auditable trail**.
- **Transport**: `gen_tcp` / `socket` on `{local, Path}` (OTP AF_UNIX). Default
  path `$XDG_RUNTIME_DIR/soma.sock`, else `/tmp/soma-$UID.sock` (mind the AF_UNIX
  path-length limit, ~104 chars on macOS). **Not** `/run` (needs root; absent on
  macOS, the verified target).
- **Framing**: length-prefixed s-expr frames. The request frame carries the
  workflow's Lisp s-expr — a `(run …)` form (the daemon parses it with
  `soma_lfe`); the reply frame carries a rendered `(result …)` s-expr
  (`soma_lisp:render/1`). No JSON on the wire — the same Lisp the workflows are
  written in is the wire format.
- **Access control**: filesystem permissions on the socket path (0600, owner-
  only). Single-user, so that is the whole boundary.

## Commands

| Target command | Current module API | Needs LLM? | Role |
|---|---|---|
| `soma daemon` | `soma_cli:daemon/1` | no | Boot runtime + listener on the socket. |
| `soma run <workflow>` | `soma_cli:run/1` | no | Run an LFE workflow under supervision; return result. |
| `soma ask "<intent>"` | `soma_cli:ask/1` | yes | Intent → LLM → proposal → policy → result. |
| `soma status <task-id>` / `soma cancel <task-id>` | `soma_cli:status/1`, `cancel/1` | no | Poll / cancel a task by id. |
| `soma trace <correlation_id>` | `soma_cli:trace/1` | no | Render a stored correlation chain as Lisp events. |

The module APIs above are what exists today. Product work remains to expose them
as a packaged external task command without colliding with relx's existing
`bin/soma` control script.

## `soma run` — deterministic supervised execution (client)

```
soma run WORKFLOW [--detach]
```

- **WORKFLOW**: a file (or `-` for stdin) — an **LFE workflow** (a `(run …)`
  s-expr, compiled via `soma_lfe:compile/2`).
- The client reads the file's s-expr and sends it as the **`(run …)` request**
  frame; the daemon parses it with `soma_lfe`, owns a supervised run, waits for
  the terminal state, and frames back a rendered **`(result …)` reply** s-expr
  (`soma_lisp:render/1`) which the client prints.
- The `(result …)` s-expr carries the terminal `status`, the `outputs`, and the
  `task_id` / `correlation_id`. Exit `0` completed, non-zero otherwise.
- With `--detach`, the client sends the same `(run …)` request with a `(detach)`
  marker. The daemon starts the run under the live-task registry and immediately
  replies with an accepted task handle:

```
(accepted (task-id "…") (correlation-id "…"))
```

  A detached accepted reply exits `0`; the task continues after the client
  disconnects and can be managed with `soma status <task-id>`, `soma trace
  <correlation-id>`, or `soma cancel <task-id>`.

## `soma ask` — the agent (client)

```
soma ask "INTENT" [--detach]
```

`soma ask` drives the v0.5 decision loop — intent → LLM → proposal → policy gate
→ result — through the daemon. Like `soma run`, the wire is all-Lisp: the client
turns the intent into an `(ask …)` request s-expr, the daemon parses it with
`soma_lfe`, runs the loop on a `soma_actor`, and frames back a rendered
`(result …)` reply s-expr (`soma_lisp:render/1`) that the client prints. Exit `0`
on `(status completed)`, non-zero otherwise.

Detached execution is implemented for `(run ...)` requests. `soma_cli:ask/1` can
construct a detach marker for future command UX, but daemon-side detached ask
execution is not yet a live path.

### The `(ask …)` request

The request frame carries an `(ask …)` form. `soma_cli:ask/1` builds the minimal
`(ask (intent "…"))` from the intent string today; the full form the daemon
parses is:

```
(ask
  (intent "summarize the build log")   ; required — the natural-language ask
  (allow echo file_read)               ; optional — tool-name allowlist (policy gate)
  (budget-llm 3)                        ; optional — max LLM calls
  (budget-steps 5))                     ; optional — max run steps
```

`(intent "…")` is the only required sub-form; an `(ask …)` with no `(intent …)`
is a parse error, not a malformed ok map. `(allow t1 t2 …)` collects bare tool
symbols into the policy gate's allowlist; `(budget-llm N)` / `(budget-steps N)`
set the two budget caps. The allowlist and budgets nest inside the `ask` form so
one request frame is self-contained — the client never sends a model: the
provider and its key live at the daemon, not on the wire.

### The `(result …)` reply

The reply is the same `(result …)` s-expr `soma run` returns. On a `reply`
proposal the answer text rides under the existing `(outputs …)` sub-form:

```
(result
  (status completed)
  (task-id "…") (correlation-id "…")
  (outputs "the build failed in the link step …"))
```

Reusing `(outputs …)` keeps the renderer unchanged — no new reply sub-form. Two
non-`completed` outcomes carry their reason under the `(error …)` sub-form the
renderer already emits:

- **`rejected`** — the policy gate rejects the proposal: `(status rejected)` with
  the reject reason under `(error …)`.
- **`budget_exceeded`** — `(budget-llm 0)` refuses up front before any LLM call:
  a non-`completed` status whose `(error …)` carries
  `(budget_exceeded max_llm_calls)`.

### Mock-on-gate vs real-provider-by-config

The LLM provider is **server config, not a wire field** — the daemon's
`model_config`, never the request. This is the security boundary (the key and
provider live at the daemon) and it is what makes the test gate hermetic:

- **mock-on-gate** — the gate's `model_config` is a mock directive map (no real
  provider, no network), so the loop runs entirely in-BEAM. `soma ask`'s `reply`
  / `rejected` / `budget_exceeded` cases are all proven against the mock; the
  same bar CLI.1b held.
- **real-provider-by-config** — the real `soma_llm_openai` provider is wired by
  setting the daemon's `model_config` when `soma daemon` starts (`base_url` /
  `model` from config, **API key only from the daemon's env** — clients never
  pass a key). Swapping the config swaps the brain; the request form and the
  `(result …)` reply are identical either way.

**Near-term scope:** the real provider initially returns only `reply` proposals
(a text answer), so `soma ask` answers in text and does **not** yet execute
tools. The policy gate, `(allow …)`, and `(budget-steps …)` are wired through to
the actor but inert for a `reply` — the one budget effect a reply can show is the
`(budget-llm 0)` up-front refusal. They become load-bearing once structured
(`run_steps`) proposals land (the real planner); until then they are accepted but
inert for a `reply`.

## `soma status` / `soma cancel` / `soma trace` — task commands over the Lisp wire

```
soma status TASK_ID
soma cancel TASK_ID
soma trace  CORRELATION_ID
```

These clients use the same local socket framing as `soma run`: each builds a
one-line Lisp request s-expr client-side, sends one frame, reads one reply, and
prints stdout as clean Lisp. `status` and `trace` are read-only and always exit
`0` on a successful read. `cancel` is a write command against a live task id; it
does not start a new run or actor.

### `soma trace` — render a stored correlation chain

`soma_cli:trace/1` sends a `(trace "<correlation-id>")` request frame. The daemon
fetches that correlation's events (`soma_event_store:by_correlation/2`), renders
each as an `(event …)` s-expr in **timestamp order** (`soma_trace:render_lisp/2`),
and frames them back wrapped in a single `(trace …)` head:

```
(trace
  (event …)        ; … run.started …
  (event …)        ; … step / tool-call events …
  (event …))       ; the last by timestamp — for a completed run, run.completed
```

The trace request takes the **`correlation-id`** off a prior `(result …)` reply.

### `soma status` — a task's state by id

`soma_cli:status/1` sends a `(status "<task-id>")` request frame. The daemon looks
the task up by its id and frames back a `(status (state …))` reply:

```
(status (state running))        ; a detached run still executing in the registry
(status (state completed))      ; a run that recorded run.completed
(status (state failed))         ; failed / timeout / cancelled map to that state
(status (state unknown))        ; no events for that id (an unknown task)
```

The daemon checks the live-task registry first, so a detached task can report
`running` before any terminal event exists. If the registry has no entry, the
state is derived from the task's events: a `run.completed` event → `completed`;
a `run.failed` / `run.timeout` / `run.cancelled` event → that terminal state; **no
events for the id → `unknown`**. An unknown id is answered, not an error — the
daemon stays up for the next connection. The fallback lookup reaches a task's
events through `by_session/2` because the run path aliases the run's `session_id`
to its `task-id`; the store has no separate `by_task` query. The status request
takes the **`task-id`** off a prior `(result …)` or `(accepted …)` reply.

### `soma cancel <task-id>` — cancel a live detached task

`soma_cli:cancel/1` sends a `(cancel "<task-id>")` request frame. For a running
detached task, the daemon asks the live-task registry to send `cancel` to the
stored `soma_run` pid. The run remains responsible for stopping its active
tool-call worker, tearing down any external OS child, emitting `run.cancelled`,
and reporting its terminal state. A successful live cancellation replies:

```
(result (status cancelled) (task-id "…") (correlation-id "…"))
```

If the task is already terminal, cancel does not re-run or re-cancel it:

```
(result (status completed) (note already-terminal))
```

An unknown id is answered as data, not as a daemon crash:

```
(result (status unknown) (error not-found))
```

## Output for agent consumption

`soma run` prints one **`(result …)` s-expr** on stdout — `(result (status …)
(task-id …) (correlation-id …) (outputs …))`, with an `(error …)` sub-form on
failure — plus a meaningful exit code (`0` on `(status completed)`, non-zero otherwise).
Diagnostics go to stderr
so stdout stays a clean s-expr. **Identifiers**: `soma status` / `soma cancel`
take the `task-id`, `soma trace` takes the `correlation-id`.

**Erlang-term → Lisp rendering** (`soma_lisp:render/1`, the same renderer the
audit trace uses): atoms → symbols, binaries → `"strings"`, integers/floats →
numbers, maps → nested `(key value)` forms, lists → `(a b c)`, and a reason tuple
`{Tag, Detail…}` → `(Tag Detail…)`. The same Lisp the workflows are written in is
what comes back — no JSON anywhere.

## Connection / cancellation semantics

- **Synchronous `run`**: if the client disconnects (Ctrl-C, the agent's own
  timeout, a dropped socket) the daemon **cancels** the in-flight run — no
  orphaned work piling up on the shared daemon.
- **Fire-and-forget** (`--detach`): the task keeps running after the client
  leaves; reattach/manage via `soma status <task-id>` / `soma cancel <task-id>`.
- A task already in a terminal state is never cancelled or re-run.

## What the daemon unlocks

The daemon is where v0.4 (long-lived actors) and v0.6 (persistent store) pay off
— in a one-shot CLI they are born and die per call. With a daemon: actors
persist, the event store is shared and durable, tasks outlive the client, you get
one audit trail, and there is no boot cost per call.

## Limitations & operational notes (the bill for "long-lived")

Honest costs of a long-lived daemon, all **slow to bite at single-user scale** —
documented now, fixed later, not v1 blockers:

- **Memory grows unbounded** (node F): `soma_run` never exits its terminal state,
  the actor's task/run maps only grow, the store is append-only. A one-shot CLI
  sidesteps this by dying; the daemon cannot. *Mitigation until node F: restart
  the daemon periodically.*
- **The `halt` `disk_log` grows** (no rotation yet): the audit log file grows with
  total events; on a long-lived daemon it will eventually need rotation/compaction.
- **The event store is a single `gen_server`**: every client's `append` (now also
  the `disk_log` write) serializes through it. Fine for a few concurrent tasks;
  a throughput ceiling only under heavy concurrency — not a single-user concern.

## Implemented Slices And Remaining Work

1. **CLI.1 / CLI.1b — daemon + Unix socket + run client.** `soma_cli:daemon/1`
   and `soma_cli:run/1` (the node +
   a socket listener: accept loop, one handler process per connection, length-
   prefixed s-expr frames — the `(run …)` request parsed with `soma_lfe`, the
   `(result …)` reply rendered with `soma_lisp:render/1` — and cancel-on-
   disconnect) and a thin run client. No LLM. *Foundational.* Daemon-
   lifecycle acceptance items: an
   **atomic single-winner socket bind** (concurrent first-calls / auto-start must
   not spawn duplicate daemons) and **stale-socket cleanup** (unlink a leftover
   socket file before bind, so a restart after a crash succeeds).
2. **node B.2 — actor uses the real provider** (done): the actor's
   `model_config` can route to `soma_llm_openai`, with gate tests using a fixed
   response seam.
3. **CLI.2 — ask client** (done on the module/server path): `soma_cli:ask/1`
   drives intent through the actor decision loop.
4. **CLI.3 / follow-up — status, cancel, trace, detach** (done on the
   module/server path): `soma_cli:status/1`, `cancel/1`, `trace/1`, detached run
   ownership, and cancel-by-id are implemented and tested.
5. **Remaining product work:** external command parser / install surface,
   auto-start, a daemon config file, and any `soma stop` task-daemon command
   separate from relx's node-control `stop`.

## Open decisions (remaining)

- **Auto-start**: do clients auto-start the daemon if absent, or error with "run
  `soma daemon`"? Lean: auto-start (single-user, low risk).
- **`soma ask` config file** location/format (`~/.soma/config`), key strictly from
  the daemon's env. Lean: a small TOML at `~/.soma/config`.
- **Input formats for `soma run`**: an LFE workflow (a `(run …)` s-expr); the
  same Lisp is the wire and the file format.

# Soma CLI & daemon — design (draft, for review)

> Status: **design draft**, not yet implemented. This spec guides the CLI slices.

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

| Command | Needs LLM? | Role |
|---|---|---|
| `soma daemon` | no | Boot the service: runtime + persistent store, listen on the socket. |
| `soma run <workflow>` | no | client → run a step list / LFE workflow under supervision; return result + trace. |
| `soma ask "<intent>"` | yes (node B) | client → the agent loop: intent → LLM → proposal → policy → execute. |
| `soma status <id>` / `soma cancel <id>` | no | client → poll / cancel a task by id (tasks outlive the caller). |
| `soma trace <correlation_id>` | no | client → render a stored correlation chain as a timeline. |

`soma run` + the daemon are the **fastest deliverable** (no LLM). `soma ask`
depends on node B (the real LLM provider).

## `soma run` — deterministic supervised execution (client)

```
soma run WORKFLOW [--json] [--trace] [--root DIR] [--timeout-ms N]
```

- **WORKFLOW**: a file (or `-` for stdin) — an **LFE workflow** (a `(run …)`
  s-expr, compiled via `soma_lfe:compile/2`).
- The client reads the file's s-expr and sends it as the **`(run …)` request**
  frame; the daemon parses it with `soma_lfe`, owns a supervised run, waits for
  the terminal state, and frames back a rendered **`(result …)` reply** s-expr
  (`soma_lisp:render/1`) which the client prints. `--root` is your sandbox root
  for file tools (your own FS).
- The `(result …)` s-expr carries the terminal `status`, the `outputs`, and the
  `task_id` / `correlation_id` (the trace is added only with `--trace`). Exit `0`
  completed, non-zero otherwise.

## `soma ask` — the agent (client; needs node B)

```
soma ask "INTENT" [--model M] [--thinking] [--allow t1,t2] \
                  [--budget-llm N] [--budget-steps N] [--json] [--trace]
```

Builds an `llm` envelope from INTENT, drives the v0.5 decision loop against the
**real provider** (node B): LLM → proposal → policy gate → (approved) execute.
`--model`/`--thinking` pick the model + `enable_thinking`; `--allow` / `--budget-*`
are the guardrails. Provider `base_url`/`model` from config; **API key only from
the daemon's env** (set when `soma daemon` starts — clients never pass a key).

**Near-term scope:** the real provider initially returns only `reply` proposals
(a text answer), so `soma ask` answers in text and does **not** yet execute tools.
The policy gate, `--allow`, and `--budget-steps` become load-bearing only once
structured (`run_steps`) proposals land (the real planner); until then they are
accepted but inert for a `reply`.

## Output for agent consumption (`--json`)

One JSON object on stdout — `{status, task_id, correlation_id, outputs|reply,
trace?, error?}` — plus a meaningful exit code. Diagnostics go to stderr so stdout
stays clean JSON. **Identifiers**: `--json` returns both ids; `soma status` /
`soma cancel` take the `task_id`, `soma trace` takes the `correlation_id`.

**Erlang-term → JSON mapping** (outputs, reasons, trace carry Erlang terms, which
have no 1:1 JSON form — this is a defined, documented mapping):

- atoms & binaries → strings; integers/floats → numbers; maps → objects (keys
  stringified); lists → arrays.
- **tuples** → arrays; a structured `reason` tuple `{Tag, Detail…}` renders as
  `{"tag": "<Tag>", "detail": [<Detail…>]}` (e.g. `{budget_exceeded, max_steps}`
  → `{"tag":"budget_exceeded","detail":["max_steps"]}`), so callers can switch on
  `tag` without parsing strings.

## Connection / cancellation semantics

- **Synchronous `run` / `ask`**: if the client disconnects (Ctrl-C, the agent's
  own timeout, a dropped socket) the daemon **cancels** the in-flight run — no
  orphaned work piling up on the shared daemon.
- **Fire-and-forget** (a `--detach` flag, later): the task keeps running after the
  client leaves; reattach/manage via `soma status` / `soma cancel <id>`.
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

## Proposed slices

1. **CLI.1 — daemon + Unix socket + `soma run` client.** `soma daemon` (the node +
   a socket listener: accept loop, one handler process per connection, length-
   prefixed s-expr frames — the `(run …)` request parsed with `soma_lfe`, the
   `(result …)` reply rendered with `soma_lisp:render/1` — and cancel-on-
   disconnect) and a thin `soma run` client. No LLM. *Foundational.* Daemon-
   lifecycle acceptance items: an
   **atomic single-winner socket bind** (concurrent first-calls / auto-start must
   not spawn duplicate daemons) and **stale-socket cleanup** (unlink a leftover
   socket file before bind, so a restart after a crash succeeds).
2. **node B.2 — actor uses the real provider** (separate track): wire the actor's
   `model_config` to the real `soma_llm_openai`. The brain `soma ask` needs.
3. **CLI.2 — `soma ask`** client on node B.2.
4. **CLI.3 — `soma status` / `soma cancel` / `soma trace`** clients + daemon
   niceties (`--detach`, auto-start, `soma stop`).

## Open decisions (remaining)

- **Auto-start**: do clients auto-start the daemon if absent, or error with "run
  `soma daemon`"? Lean: auto-start (single-user, low risk).
- **`soma ask` config file** location/format (`~/.soma/config`), key strictly from
  the daemon's env. Lean: a small TOML at `~/.soma/config`.
- **Input formats for `soma run`**: an LFE workflow (a `(run …)` s-expr); the
  same Lisp is the wire and the file format.

---
title: Erlang/OTP primer
description: Background for readers new to Erlang — what Erlang, BEAM, process, mailbox, OTP, supervisor, gen_server, gen_statem, application, and release mean, and how Soma maps each of them onto its agent runtime.
---

This page is for readers who don't know Erlang. It explains the concepts that
show up constantly in the Soma docs: Erlang, BEAM, process, mailbox, OTP,
supervisor, `gen_server`, `gen_statem`, application, and release.

The one-line version:

```text
Erlang gives you lightweight processes, mailboxes, and message passing.
OTP gives you the framework, behaviours, and supervision patterns for building reliable concurrent systems.
Soma uses Erlang/OTP to implement the agent entity and the run/tool/LLM calls it starts.
```

## What Erlang is

Erlang is a language designed for highly concurrent, highly available systems.
It grew up in telecoms, and its core strength is letting a large number of
independent tasks run for a long time, talk to each other, and keep going when
one part fails — without dragging the whole system down.

The Erlang features Soma cares about:

- lightweight processes;
- a private mailbox per process;
- communication between processes by message passing;
- no shared process state by default;
- processes can be monitored, linked, and supervised;
- one process crashing can be treated as ordinary system behavior.

These fit an agent runtime well, because an agent system naturally runs into:

- an LLM call that hangs;
- a tool call that times out;
- an external process that crashes;
- a user cancelling a task;
- one task failing while the actor/session must stay alive;
- a need for every action to be auditable.

## What BEAM is

BEAM is Erlang's virtual machine. Erlang code runs on BEAM.

Roughly:

```text
Erlang source
  -> compile
  -> BEAM bytecode
  -> run on the BEAM VM
```

BEAM provides:

- a large number of lightweight processes;
- preemptive scheduling;
- process mailboxes;
- message passing;
- fault isolation;
- timers;
- ports;
- hot code loading, among other low-level capabilities.

When the Soma docs say "in-BEAM tool," they mean a tool that runs directly
inside BEAM as an Erlang module — for example `echo`, `sleep`, `file_read`,
`file_write`.

## What an Erlang process is

An Erlang process is not an OS process. It's a lightweight process living inside
the BEAM VM.

The difference:

```text
OS process
  - an operating-system-level process
  - relatively expensive to create
  - its own address space

Erlang process
  - a lightweight process inside the BEAM VM
  - cheap to create
  - has its own mailbox and state
  - talks to other Erlang processes by message
```

In Soma:

```text
soma_actor      can be a long-lived Erlang process
soma_run        is the Erlang process for one run
soma_tool_call  is the short-lived Erlang process for one tool invocation
```

## What the actor model is

The core of the actor model is:

```text
an actor owns its own state;
an actor has its own mailbox;
an actor communicates by message;
an actor does not share internal state directly.
```

Erlang processes implement the actor model naturally:

```text
Erlang process = actor
mailbox        = actor inbox
Pid ! Message  = send message
receive        = process message handling
```

Soma's design has two layers of actor semantics:

```text
Erlang actor model
  -> the foundation: process, mailbox, message, monitor, supervisor

soma_actor
  -> the domain abstraction: a long-lived agent entity capable of LLM calls
```

So `soma_actor` is not simply "wrap one LLM call in a process." It's a long-lived
agent entity with identity, state, memory/context, model config, tool policy,
and active tasks.

## Mailbox and message passing

Every Erlang process has a mailbox. Other processes can send messages to it.

For example:

```erlang
ActorPid ! {actor_message, Envelope}
```

This is not a function call. The sender drops the message into the target
process's mailbox; the target decides when to handle it, driven by its own event
loop / state machine.

This matters for Soma:

- `soma_actor` is triggered by messages;
- `soma_actor` instances talk to each other by message;
- the result of `soma_llm_call` comes back to `soma_actor` as a message;
- the result of `soma_run` comes back to the session/actor as a message;
- the result of `soma_tool_call` comes back to `soma_run` as a message.

This boundary guarantees that a sub-operation can't mutate the parent's state
directly — it can only send a result. The parent receives the message and decides
its own state transition.

## What OTP is

OTP stands for **Open Telecom Platform**. Today, OTP usually means the standard
library, frameworks, and design patterns the Erlang ecosystem provides for
building reliable concurrent systems.

One way to see it:

```text
Erlang = language + VM + lightweight processes + mailbox + message passing
OTP    = supervisor + gen_server + gen_statem + application + release, the engineering frameworks
```

OTP's job is to organize Erlang's concurrency into maintainable, restartable,
releasable production systems.

## What a behaviour is

A behaviour is a kind of "callback protocol" in Erlang/OTP.

A behaviour defines:

```text
which callbacks you have to implement;
when the OTP runtime will call them;
how the standard framework runs your module.
```

Common OTP behaviours:

- `gen_server`
- `gen_statem`
- `supervisor`
- `application`

Soma also defines its own tool behaviour:

```erlang
-callback describe() -> soma_tool:spec().
-callback invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
```

This gives every tool the same shape.

## What `gen_server` is

`gen_server` is OTP's generic server-process pattern.

It suits processes that are long-lived, hold internal state, and handle requests.

Typical capabilities:

- initialize state;
- synchronous requests;
- asynchronous messages;
- plain process messages;
- lifecycle callbacks such as terminate / code change.

Objects in Soma that fit `gen_server`:

```text
soma_agent_session  long-lived session process
soma_event_store    in-memory event store
soma_tool_registry  tool registry
```

A future simple `soma_actor` could also start out as a `gen_server`, but once the
actor's state transitions get complicated, `gen_statem` is the better fit.

## What `gen_statem` is

`gen_statem` is OTP's state-machine process pattern.

It suits processes with clear state transitions.

For example, `soma_run`:

```text
executing
  -> waiting_tool
  -> completed | failed | timeout | cancelled
```

A future `soma_actor` is also a good fit for `gen_statem`:

```text
idle
  -> thinking
  -> waiting_llm
  -> running
  -> replying
  -> idle
```

The advantage of `gen_statem` is that the state names are part of the design:
timeout/cancel/result all land clearly on state transitions.

## What a supervisor is

A supervisor is OTP's supervising process.

It doesn't carry business logic; it starts, monitors, and restarts child
processes.

A typical supervision tree:

```text
top_sup
  ├── event_store
  ├── registry
  ├── actor_sup
  └── run_sup
```

A supervisor lets the system treat failure as an ordinary event:

```text
child process crashed
  -> supervisor observes exit
  -> restart or leave stopped according to policy
```

In Soma:

- `soma_sup` is the top-level supervisor;
- `soma_session_sup` manages sessions;
- `soma_run_sup` manages runs;
- there can be a `soma_actor_sup` for actors;
- there can be a `soma_llm_call_sup` for one-shot LLM-call workers.

## Link and monitor

Link and monitor are both Erlang mechanisms for observing a process's lifecycle.

Simplified:

```text
link
  - establishes a failure-propagation relationship between processes
  - when a linked process crashes, the other usually receives an exit signal

monitor
  - one-way observation
  - when the monitored process exits, the monitor receives a 'DOWN' message
  - it does not automatically take the monitor down with it
```

Soma uses monitors heavily:

```text
soma_run monitors soma_tool_call
soma_actor monitors soma_run / soma_llm_call
```

This way, when a sub-operation crashes, the parent receives it as data:

```erlang
{'DOWN', MRef, process, Pid, Reason}
```

The parent can record it as `run.failed`, `task.failed`, or `llm.failed` instead
of crashing along with it.

## What an application is

An OTP application is a startable unit in an Erlang system.

It usually contains:

- `.app.src` metadata;
- an application callback module;
- a supervision tree;
- dependency declarations;
- source, tests, priv files, and so on.

Soma today is a rebar3 umbrella containing several OTP applications:

```text
apps/soma_runtime
apps/soma_tools
apps/soma_event_store
```

`application:ensure_all_started(soma_runtime)` starts `soma_runtime` and its
dependencies.

## What a release is

A release is a publishable, runnable Erlang system package.

It bundles the applications it needs, their dependencies, configuration, and
optionally ERTS.

Soma's release goal is:

```text
users don't need Erlang installed on their machine;
unpacking the release tarball is enough to run soma.
```

A self-contained release — the term used in the docs — is a release that bundles
the Erlang runtime.

## What a port is

A port is BEAM's mechanism for talking to an external OS process.

Soma's CLI tool adapter uses a port to launch an external executable:

```text
soma_tool_call
  -> open_port({spawn_executable, Executable}, Args)
  -> external OS process
```

This is different from an Erlang process:

```text
Erlang process
  - a lightweight process inside BEAM

External OS process
  - an operating-system process
  - managed and communicated with by BEAM through a port
```

Soma's constraints on CLI tools:

- use executable + argv;
- never use a shell command string;
- on timeout/cancel, kill the worker and the external OS process;
- bound the size of stdout/stderr output;
- normalize a non-zero exit into `{error, Reason}`.

## What a rebar3 umbrella is

rebar3 is Erlang's build tool.

An umbrella repo is a project structure containing several OTP applications:

```text
soma/
  rebar.config
  apps/
    soma_runtime/
    soma_tools/
    soma_event_store/
```

This fits Soma, because runtime, tools, and event store are distinct boundaries
that still need to be built and tested together as one system.

## How Soma concepts map onto Erlang/OTP

| Soma concept | Erlang/OTP counterpart |
|---|---|
| `soma_actor` | long-lived Erlang process, ideally `gen_statem` |
| actor mailbox | Erlang process mailbox |
| actor message | Erlang message envelope |
| actor state | `gen_server` / `gen_statem` state |
| actor policy | actor state + validation module |
| `soma_llm_call` | one-shot worker process |
| `soma_run` | per-run `gen_statem` |
| `soma_tool_call` | one-shot worker process |
| tool crash | monitor `'DOWN'` message |
| timeout | timer / `state_timeout` |
| cancellation | message + child teardown |
| event store | `gen_server` |
| tool registry | `gen_server` |
| external CLI tool | OS process via port |
| release | OTP release tarball |

## Why this fits Soma

The hard part of an agent runtime isn't "call an LLM once" or "call one tool."
It's:

- long-lived entities;
- multiple concurrent tasks;
- sub-operations timing out;
- user cancellation;
- isolating local failures;
- event auditing;
- actor-to-actor messages;
- not letting the LLM directly hold execution rights.

Erlang/OTP provides exactly this set of low-level semantics:

```text
process       -> the isolation boundary for entity / run / call
mailbox       -> the message inbox
supervisor    -> lifecycle and recovery
monitor       -> observing sub-operation results and crashes
gen_statem    -> explicit state transitions
timer         -> timeouts
event store   -> an auditable trail
port          -> the boundary to external programs
```

Soma's design puts these mechanisms to work in an agent runtime:

```text
soma_actor is the agent entity;
soma_run is the path that executes a fixed list of steps;
soma_tool_call / soma_llm_call are supervised sub-operations;
events are the source of truth.
```

## Glossary

| Term | Short explanation |
|---|---|
| Erlang | a language designed for highly concurrent, highly available systems |
| BEAM | Erlang's virtual machine |
| Erlang process | a lightweight process inside BEAM, not an OS process |
| mailbox | the message queue of each Erlang process |
| message passing | processes communicating by sending messages |
| actor model | a concurrency model of independent entities communicating by message |
| OTP | Open Telecom Platform — frameworks and patterns for reliable Erlang systems |
| behaviour | a callback protocol, e.g. `gen_server`, `gen_statem` |
| `gen_server` | the long-lived server-process pattern |
| `gen_statem` | the state-machine process pattern |
| supervisor | a supervisor that starts, monitors, and restarts child processes |
| monitor | one-way observation of a process exit, receiving a `'DOWN'` message |
| link | a failure-propagation relationship between processes |
| application | a startable OTP application unit |
| release | a publishable, runnable Erlang system package |
| port | BEAM's mechanism for talking to an external OS process |
| rebar3 | Erlang's build tool |
| umbrella | a structure with several OTP applications in one repo |

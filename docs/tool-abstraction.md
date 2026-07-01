# Soma tool abstraction and third-party integration

> Status: design / proposal (not yet sliced into issues)
> Related: `docs/tool-manifest.md` (the shipped v0.2 manifest contract),
> `docs/roadmap.md` (node B planning, effect-aware policy, MCP),
> issue #175 (the docmod scenario — the first consumer of this design),
> and the cove-go tool-abstraction design (an external convergent design;
> its `Effect = Identity | Reader | State` typing is the same effect model
> soma's manifests already declare).

## 1. What a tool is in soma today

A soma tool is **a self-describing invocation that always crosses a process
boundary**. Three pieces define it, all shipped since v0.1/v0.2:

1. **The behaviour** (`soma_tool`): `describe/0` returns the spec,
   `invoke/2 :: (input, ctx) -> {ok, output} | {error, error}` does the work.
   Contract only — no logic in the behaviour module.
2. **The manifest** (`soma_tool_manifest:normalize/1`): the tool's
   machine-readable self-description. Required fields today:

   ```erlang
   #{name       => atom(),
     effect     => identity | reader | state,
     idempotent => boolean(),
     timeout_ms => pos_integer(),
     adapter    => erlang_module | cli,
     %% adapter fields:
     module => module()                          % erlang_module
     executable => path, argv => [arg]}          % cli
   ```

   A malformed manifest is rejected with a named `{error, _}` and never
   reaches the registry — validate at the edge, fail closed.
3. **The execution boundary** (`soma_run` → `soma_tool_call`): every
   invocation runs in a disposable, monitored worker. The result comes back
   as a message; a crash arrives as the monitor's `'DOWN'`; timeout and
   cancel are enforced by the owning run, which also tears down a `cli`
   tool's external OS process. The registry (`soma_tool_registry`) maps
   `name => descriptor` and is the single resolution path.

The `effect` / `idempotent` fields are already load-bearing: the v0.7 resume
planner classifies an in-flight step through them (safe = `reader` /
`identity` / `idempotent`; unsafe = non-idempotent `state`), and the planned
effect-aware policy gate will read the same fields at decision time.

## 2. The abstraction, stated once

A tool is the unit of the model's (and any caller's) action on the world.
Its true signature is not `Args -> Result` but

```text
Tool : Args -> M Result        where M ∈ {Identity, Reader World, State World}
```

`effect` in the manifest *is* `M`. `identity` tools are pure; `reader` tools
depend on world state but do not change it; `state` tools change it. This is
a type-level property the runtime dispatches on — never a comment. Everything
below preserves two invariants:

- **The manifest is the whole truth about a tool.** Two halves:
  - the **runtime-facing half** (`effect`, `idempotent`, `timeout_ms`,
    `adapter` + adapter fields) — consumed by the run, the resume planner,
    and the policy gate;
  - the **model-facing half** (new, §3: `description`, `params`) — consumed
    by a planning LLM deciding what to call and how.
  A capability that cannot state its manifest honestly does not become a
  tool.
- **Cross-cutting policy is process ownership, not wrapping.** Where a
  middleware-style design stacks decorators (timeout → retry → audit →
  rate-limit), soma already assigns each concern to the process that owns
  it. Do not add a decorator layer; it would duplicate OTP ownership:

  | Concern | Soma's owner |
  | --- | --- |
  | Timeout | `soma_run`'s `state_timeout`, plus manifest `timeout_ms` |
  | Teardown | the run holds the worker monitor and the external OS pid |
  | Retry | none automatic; `state` is never blindly re-run (same rule as resume's fail-safe) |
  | Audit | the mandatory event store (`tool.started` / `tool.succeeded` / …) |
  | Admission | `soma_policy:check/2` before execution; per-task `budget` |
  | Error normalization | each adapter's bounded `{error, _}` vocabulary |

## 3. Manifest v2 — the model-facing half

To let a planning model choose tools (node B planning mode already parses
`(run-steps …)` proposals), the manifest gains two **optional** fields:

```erlang
#{description => binary(),          % one-paragraph prose for the model
  params => [#{name := binary(),    % declared parameters
               type := string | integer | boolean,
               required := boolean(),
               doc => binary()}]}
```

- `soma_tool_manifest:normalize/1` validates them when present; absent means
  "not offered to planners" (the tool stays callable from explicit step
  lists — today's behavior, unchanged byte for byte).
- `soma_tool_registry:catalog/0` returns the model-facing halves of every
  descriptor that has one. The planning prompt embeds the catalog as Lisp
  forms, so the model proposes steps against tools that actually exist —
  and policy still gates the proposal afterwards. The catalog never leaks
  runtime-facing internals (`module`, `executable`, paths).
- `params` is soma-shaped data, not JSON Schema. It renders to a Lisp form
  spec for planning prompts, and can later render to JSON Schema at an MCP
  boundary. One source, two renderings.
- No `latency_class` field: soma's required `timeout_ms` is the stronger
  form — a declared, owner-enforced hard bound rather than an advisory class.

## 4. Execution locations: the adapter vocabulary does not grow

The two adapters are deliberately sufficient:

- **`erlang_module`** — the universal in-BEAM indirection. Any capability
  that can be fronted by an Erlang module is this adapter, including ones
  whose implementation talks to a database, a socket, or another actor.
- **`cli`** — the one-shot external executable (executable + argv, no shell,
  input as final argv argument, minimal env, fixed cwd, real OS-pid
  teardown). This is the primary third-party path.

Richer integrations are **capability apps, not new adapter enum values**: a
new OTP app owns its infrastructure (a supervised client/store process) and
exposes its capability as `erlang_module` tools registered at boot. The tool
module is a thin translation layer; the supervised server owns connections,
state, and teardown. This keeps `soma_tool_call` closed and the adapter
vocabulary auditable.

The dependency rule survives because **the registry is the indirection**: a
tool module may live in `soma_actor` or a future `soma_memory` / `soma_mcp`
app, and `soma_tool_call` calls it late-bound through the descriptor. No
runtime source ever names an upper-layer module; upper layers register
downward at boot. (`soma_runtime` still never *imports* anything above it.)

Planned capability apps on this pattern:

| Capability | App | Tools (effect) | Infrastructure it owns |
| --- | --- | --- | --- |
| Memory (§6) | `soma_memory` | `memory_get`, `memory_search` (reader); `memory_put`, `memory_del` (state, idempotent) | a supervised keyed store on disk |
| Sub-agent as tool | `soma_actor` | `ask_actor` (declared per target; conservative default `state`, non-idempotent) | the existing actor registry + `ask/3` |
| MCP (roadmap, post-validation) | `soma_mcp` | one registered tool per remote MCP tool | a supervised MCP client per server |
| Human/delegator ask (P14) | `soma_actor` or CLI layer | `ask_human` (reader-shaped, blocks on an answer) | the CLI wire / a pending-question store |

Sub-agent note: `ask_actor`'s worker blocks in `soma_actor:ask/3` with the
step's timeout; the sender's `correlation_id` propagates (proven since
v0.5.6), so the sub-agent's whole chain lands on the same trace. Cancelling
the run kills the worker; cancel propagation to the sub-task rides the
`task_id` the worker obtained.

## 5. Third-party integration recipes

Three tiers, cheapest first:

1. **Wrap a binary (no Erlang written).** Write a manifest for the existing
   `cli` adapter and register it. This is docmod (#175): `docmod_read`
   (`reader`, idempotent), `docmod_edit` (`state`, **not** idempotent — the
   resume planner and the future effect-aware policy then treat it correctly
   for free), with the stdin seam bridged by a file (`--changes-file` or a
   wrapper script) because the `cli` protocol is argv-in / stdout-out.
2. **Config-registered tools (productized tier 1).** At daemon boot, load
   `~/.soma/tools/*.lisp`, each one a `(tool …)` form:

   ```lisp
   (tool
     (name "docmod_read")
     (description "Read a .docx as flat HTML for editing.")
     (effect reader) (idempotent true) (timeout-ms 30000)
     (adapter cli)
     (executable "/Users/me/code/docmod/dist/osx-arm64/docmod")
     (argv "read" "--outline")
     (params (("path" string required "Path to the .docx"))))
   ```

   Parsed by the existing Lisp reader (Lisp at the edge), compiled to a
   manifest map, then through the same `normalize/1` — one validation path
   for built-in and external tools. A file that fails to parse or normalize
   is **skipped with a named diagnostic** (an event + a boot log line); a
   broken tool file must not stop the daemon. Effect fields are declared by
   the user; anything undeclared defaults conservatively to
   `state` + `idempotent => false` (never guess a tool is safe).

   Atom policy: registry keys are atoms, and manifests arrive as text. Tool
   names from `~/.soma/tools/` are converted at **boot only**, from the
   user's own trusted local files, bounded by file count — never from wire
   input or model output. A proposal naming an unknown tool still resolves
   to `{error, not_found}` and is rejected; the wire never mints atoms.
3. **Capability app (full citizenship).** For anything needing a live
   connection, local state, or protocol handling: an OTP app owning a
   supervised server, exposing `erlang_module` tools (§4). MCP lands this
   way when it lands.

## 6. Memory as tools

Memory enters the model's action space — reading and writing it are actions
the model (or a step list) takes — so **memory's surface is tools**, while
the memory *store* is infrastructure (like the event store: never a tool).

- `soma_memory` app: a supervised `soma_memory_store` (keyed, disk-backed,
  under a configured directory) plus four thin tool modules.
- Effects, declared honestly:
  - `memory_get`, `memory_search` — `reader`, idempotent;
  - `memory_put` — **`state`, `idempotent => true`**: a keyed upsert, so
    re-running it converges. A resumed run may safely repeat an in-flight
    `memory_put`; nothing new is needed in the resume planner — the
    classification falls out of the manifest.
  - `memory_del` — `state`, idempotent (deleting twice converges).
- Everything the runtime already guarantees applies with zero new
  machinery: writes appear on the event trail (`tool.*` events, the audit),
  the policy gate can deny memory writes in a read-only policy (effect-aware
  policy makes that one line), budgets bound how much a task may touch
  memory, and durable-store deployments replay memory *activity* on the same
  trail as everything else.

This is the test of the whole design: a genuinely new capability lands as
one app + four manifests, and inherits supervision, audit, policy, budget,
resume classification, and tracing without touching `soma_run`,
`soma_tool_call`, or the actor.

## 7. What is not a tool

The criterion: **does it enter the model's action space?** Only then is it a
tool.

- Not tools: the event store, the registry, the Unix-socket wire, sessions /
  runs / actors themselves, the memory store behind the memory tools, a
  future MCP client connection. These are infrastructure or the environment
  tools act in.
- Also not tools: replying to the caller and finishing a task — those are
  proposal kinds (`reply`, `reject`), actions of a different type in the
  actor's decision loop, exactly parallel to keeping `respond`/`terminate`
  out of a chat agent's tool list.
- Borderline, resolved: asking a human (`P14`) **is** a tool-shaped action
  (a discrete request/response mid-task), and lands as `ask_human` in §4's
  table when the pending-question path exists.

## 8. Sequencing

Each slice is independently green and contract-proven, in the usual order:

1. **T.1 — manifest v2 + catalog**: optional `description` / `params`,
   `catalog/0`, planning prompt consumes the catalog. Additive; existing
   manifests unchanged.
2. **T.2 — config-registered cli tools**: `~/.soma/tools/*.lisp` at daemon
   boot, one validation path, skip-with-diagnostic. Unlocks #175's docmod
   tools without hardcoding them into the release.
3. **T.3 — `soma_memory`**: the store server + the four tools (§6).
4. **T.4 — `ask_actor`**: sub-agent as tool, cancel propagation proven.
5. **T.5 — `soma_mcp`**: post-validation, per the roadmap; by then it is
   "one more capability app", not a runtime change.

Effect-aware policy (`docs/roadmap.md`, node B "later") pairs naturally with
T.2/T.3 — the moment third-party `state` tools and memory writes exist,
"read-only mode" stops being theoretical.

## 9. Non-negotiables this design keeps

- Every invocation crosses a process boundary; results are messages.
- Executable + argv, never shell strings; minimal env; fixed cwd; real
  external-process teardown.
- Manifests validate at the edge and fail closed; unknown effect metadata
  defaults to the most conservative class.
- No atoms from wire or model input; boot-time config is the only text →
  atom edge, and it is bounded and local-trusted.
- The runtime never imports upper layers; upper layers register tools
  downward through the registry.
- Tools never own run state or long-lived state; state lives behind
  supervised servers, and the tool is the message-passing surface over it.

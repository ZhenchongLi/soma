# Soma Lisp message language

> Status: L.1-L.5 are implemented and covered by contract tests. The language is
> still intentionally constrained: Lisp is accepted at the system edges and parsed
> into existing Erlang maps; it is not the runtime's internal representation and
> not a general Lisp evaluator.

## Vision

Make **Lisp s-expressions the message / interchange language** between soma's
actors and agents. soma is then "OTP supervision + a homoiconic message
language": Erlang/OTP gives the execution semantics (the thesis), Lisp gives the
agents a single **code-as-data** language to talk in. This also turns the
already-built but orphaned `soma_lfe` (v0.3, "Lisp → step list") into a central
piece: it grows into the message parser.

## The load-bearing decision: Lisp at the edges, Erlang at the core

- **Lisp s-exprs are the message / interchange format** at every agent boundary:
  client → actor, actor → actor, LLM → actor, and the form recorded for audit.
  Each message is parsed **at the boundary** into the existing internal maps
  (envelope / step list / proposal).
- **The execution substrate and BEAM inter-process message-passing stay Erlang** —
  supervision, monitors, crash isolation, the actor model. We do **not** make
  s-exprs the internal representation; that would fight OTP, which is the whole
  point of soma.

One line: **Lisp flows between agents; Erlang executes in the core.**

## The wire protocol speaks Lisp too (CLI.1b + L.4)

The client↔daemon channel carries **Lisp s-exprs, not JSON** — pushing "Lisp at
the edges" all the way to the wire. The request is an s-expr the daemon parses
with `soma_lfe` (it *is* the protocol parser); the response is an s-expr produced
by the **term→Lisp renderer** (L.4), which also renders the audit trace. So
`soma_lfe` is the single bidirectional protocol boundary; only the BEAM-internal
terms stay Erlang.

```lisp
(run (step s1 echo (args (value "hi"))))                                       ; request
(result (status completed) (task-id "t-7") (outputs ((s1 (value "hi")))) (correlation-id "c-7")) ; response
```

`soma run` takes a `.lfe` workflow **only** — no JSON input. The trade: the wire
is soma-Lisp, not universal JSON; fine for the single-user / own-agents scope,
where agents emit Lisp and L.5 repairs imperfect Lisp.

**Not Turing-complete (yet) — and that's deliberate.** s-exprs *can* express
Turing-complete programs (Lisp is), but soma's grammar + runtime are a constrained
subset: `soma_lfe` compiles to a flat **sequential** step list — no `if` / `cond`
/ `loop`, no branching. So this is "Lisp as the message/plan *syntax*," not a
Turing-complete interpreter. The s-expr substrate leaves room to grow toward real
control flow later (JSON could not); but *executing* control flow needs runtime
branching — that is v0.8 (DAG), a separate, bigger step.

## The homoiconic payoff

A Lisp message can be **data or an executable plan — one language**, so an agent
can construct / inspect / transform / forward messages as data:

```lisp
(send "log-summarizer"                         ; actor-to-actor send
  (msg (type chat)
       (payload (goal "summarize today's errors"))
       (steps (step (id s1) (tool file-read) (args (path "/var/log/app.log")))
              (step (id s2) (tool echo)      (args (value (from-step s1)))))))

(reply (text "3 errors, all timeouts"))         ; a proposal — also an s-expr
```

JSON/maps can't give this; s-exprs can. That is the differentiator.

## Grammar (implemented subset — extends `soma_lfe`)

`soma_lfe` parses a constrained Lisp grammar into existing internal maps. The
implemented top-level forms are:

| s-expr form | parses into |
|---|---|
| `(task ...)` | `#{run => #{steps => [...]}}` |
| `(msg (type T) (payload …) (steps …) (llm …) (correlation-id "…"))` | an envelope `#{type, payload, steps?, llm?, correlation_id?}` |
| `(step (id s1) (tool echo) (args (value "hi")))`, `(from-step s1)` | a step map (the existing v0.3 grammar) |
| `(reply (text "…"))` / `(run-steps (step …) …)` / `(reject (reason "..."))` | a proposal `#{kind, …}` accepted by `soma_proposal:normalize/1` |
| `(ask (intent "…") (allow echo) (budget-llm 1) (budget-steps 3))` | a CLI ask command map |
| `(trace "corr")`, `(status "task")`, `(cancel "task")`, `(stop)` | CLI read/manage command maps |

Lexical mapping: symbols/keywords → atoms, strings → binaries, nested forms →
maps/lists. `soma_lfe:compile/2` returns `{ok, Map} | {error, [Diagnostic]}` as
today — the diagnostics are what the repair loop (below) feeds back to the LLM.

Actor-to-actor Lisp delivery is implemented through the existing `actor_message`
proposal path: the delivered body can be a Lisp `(msg ...)` string that the
receiving actor parses at its own boundary. A standalone top-level `(send ...)`
command and Lisp forms for the remaining proposal kinds (`ask`, `actor_message`)
remain future language surface.

## Self-repair (`L.5`) — the LLM fixes malformed Lisp

Because an LLM (or a hand-written message) will sometimes emit *almost*-valid
Lisp, the agent repairs it instead of just rejecting it — leveraging the LLM it
already has. The loop, with guardrails:

```
parse(LispMsg)
  ├─ {ok, Msg}            → normalize → policy gate → budget → run
  └─ {error, Diagnostics} → (repair enabled? within budget?)
        └─ LLM repair(source, Diagnostics) → parse(Repaired)
             ├─ {ok, Msg} → normalize → policy gate → budget → run
             └─ {error, _} → retry (bounded) → give up → task `failed` (data)
```

Safety constraints — without these it is dangerous:

1. **Error-path only.** Valid messages skip repair entirely — zero cost, zero
   extra LLM calls on the happy path.
2. **Repaired output re-enters the FULL pipeline** — `normalize` + the policy gate
   + budget. Repair is a *second chance to become valid*, **never a bypass**. Even
   if the LLM repairs the *meaning* wrong, policy and budget still gate it. This is
   the safety crux.
3. **Bounded + budgeted.** A max of N repair attempts; each repair is one LLM call
   that **counts against the existing per-task `budget` (v0.5.5)**; exhausting N or
   the budget → give up → task `failed` as data. No infinite loops, no runaway cost.
4. **Syntax/grammar-level.** Repair is "make it parse and satisfy the grammar,"
   not "freely rewrite intent" — and constraint 2 backstops it regardless.
5. **Mock-testable.** The repair-loop mechanics (malformed → repair → re-parse →
   run / give up) are driven by the mock on the gate; real repair quality is an
   opt-in smoke against node B.
6. **`strict` switch.** A mode that disables repair (malformed = reject) for when
   determinism is wanted. Default-on under the single-user/trusted scope.

## Slices

- **L.1** — Lisp envelope [done]: extend `soma_lfe` to parse `(msg …)` → the internal
  envelope map; `soma_actor:send/2` & `ask/3` accept a Lisp string (additive —
  map envelopes still work). Proof: a Lisp message runs identically to the
  equivalent map.
- **L.2** — actor-to-actor Lisp [done]: an existing `actor_message` proposal can
  carry a Lisp `(msg ...)` body; the receiving actor parses it (correlation_id
  preserved, per v0.5.6).
- **L.3** — Lisp proposals [done]: the mock LLM can emit a Lisp `reply` or
  `run-steps` proposal; `soma_lfe` parses it into `#{kind, …}` before the normal
  proposal normalization and policy path.
- **L.4** — Lisp audit/rendering [done]: the event store can record the s-expr form; `soma_trace`
  can render a correlation chain as readable, replayable Lisp.
- **L.5** — self-repair [done]: the parse-failure repair loop above, reusing the v0.5.5
  budget and node B for the repair call.

## Relationship to existing pieces

- **`soma_lfe`** grows from "Lisp → steps" to "Lisp → {envelope | steps | proposal
  | send}"; the existing step grammar is reused, not broken.
- **`soma_actor`** gains a Lisp message boundary (`send`/`ask` accept Lisp); the
  internal task/run model is unchanged.
- **node B** (the real provider) provides the opt-in real call path. L.3 and L.5
  stay mock/fixed-response on the gate so `rebar3 eunit && rebar3 ct` opens no
  real provider socket.
- **The CLI** naturally sends Lisp messages (`soma run` / `soma ask` can take an
  s-expr), tying the [cli.md](cli.md) daemon to this language.

## Out of scope

- **Lisp as the internal representation** — no; Erlang/OTP stays the core (the
  edges/core decision above).
- **Control flow in Lisp** (`if` / `cond` / loops) — would need runtime branching,
  which is v0.8 (DAG); until then Lisp stays a syntax for the *sequential* step
  list, not new expressiveness.
- **Multi-tenant** message auth — single-user/trusted scope, as in [cli.md](cli.md).

# Soma Lisp message language — design (draft, for review)

> Status: **design draft**, not yet implemented. Guides the Lisp (`L.*`) slices.

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

## Grammar (sketch — extends `soma_lfe`)

`soma_lfe` already parses a constrained Lisp grammar into step-list maps. This
adds top-level message forms; all parse into the existing internal maps:

| s-expr form | parses into |
|---|---|
| `(msg (type T) (payload …) (steps …) (llm …) (correlation-id "…"))` | an envelope `#{type, payload, steps?, llm?, correlation_id?}` |
| `(step (id s1) (tool echo) (args (value "hi")))`, `(from-step s1)` | a step map (the existing v0.3 grammar) |
| `(reply (text "…"))` / `(run-steps (step …) …)` / `(reject (reason …))` / `(ask (question "…"))` / `(actor-message (to "…") (payload …))` | a proposal `#{kind, …}` |
| `(send "actor-id" <msg-or-proposal>)` | deliver a message to another actor |

Lexical mapping: symbols/keywords → atoms, strings → binaries, nested forms →
maps/lists. `soma_lfe:compile/2` returns `{ok, Map} | {error, [Diagnostic]}` as
today — the diagnostics are what the repair loop (below) feeds back to the LLM.

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

- **L.1** — Lisp envelope: extend `soma_lfe` to parse `(msg …)` → the internal
  envelope map; `soma_actor:send/2` & `ask/3` accept a Lisp string (additive —
  map envelopes still work). Proof: a Lisp message runs identically to the
  equivalent map.
- **L.2** — actor-to-actor Lisp: an `(actor-message …)` / `(send …)` carries a
  Lisp s-expr; the receiving actor parses it (correlation_id preserved, per v0.5.6).
- **L.3** — Lisp proposals: the decision loop / a real provider emits a Lisp
  proposal; `soma_lfe` parses it into `#{kind, …}`. (This is where "the LLM speaks
  Lisp" becomes coherent — the whole system speaks Lisp.)
- **L.4** — Lisp audit: the event store can record the s-expr form; `soma_trace`
  can render a correlation chain as readable, replayable Lisp.
- **L.5** — self-repair: the parse-failure repair loop above, reusing the v0.5.5
  budget and node B for the repair call.

## Relationship to existing pieces

- **`soma_lfe`** grows from "Lisp → steps" to "Lisp → {envelope | steps | proposal
  | send}"; the existing step grammar is reused, not broken.
- **`soma_actor`** gains a Lisp message boundary (`send`/`ask` accept Lisp); the
  internal task/run model is unchanged.
- **node B** (the real provider) is what makes L.3 (Lisp proposals) and L.5
  (repair) real; the mock covers them on the gate.
- **The CLI** naturally sends Lisp messages (`soma run` / `soma ask` can take an
  s-expr), tying the [cli.md](cli.md) daemon to this language.

## Out of scope

- **Lisp as the internal representation** — no; Erlang/OTP stays the core (the
  edges/core decision above).
- **Control flow in Lisp** (`if` / `cond` / loops) — would need runtime branching,
  which is v0.8 (DAG); until then Lisp stays a syntax for the *sequential* step
  list, not new expressiveness.
- **Multi-tenant** message auth — single-user/trusted scope, as in [cli.md](cli.md).

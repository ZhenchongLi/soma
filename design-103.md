# L.1: Lisp envelope — soma_lfe parses (msg ...), soma_actor accepts a Lisp message

## Current state

`soma_lfe:compile/2` only knows one top-level form. It reads the source through
`soma_lfe_reader:read_forms/1`, then hands the form list to
`soma_lfe_parser:parse_run/1`, which insists on exactly one form headed by
`run` and returns `{ok, #{run => #{steps => Steps}}}`. Anything else is a
diagnostic. There is no path that produces an actor envelope.

`soma_actor:send/2` and `ask/3` only take a map. They call
`gen_statem:call(ActorRef, {send, Envelope})` straight through, and `idle/3`
runs `validate_envelope/1`, which requires `is_map(Envelope)` with `type` and
`payload` keys. A binary or string argument fails `validate_envelope/1` with
`{error, not_a_map}` — there is no Lisp boundary anywhere.

Two grammar facts matter for this slice:

- The reader's atom scanner already accepts `-`, so `correlation-id` and
  `from-step` read as the atoms `'correlation-id'` and `'from-step'`. Strings
  read as binaries, bare symbols as atoms, integers as integers, nested parens
  as lists. No reader change is needed.
- The existing step grammar is **positional**: `parse_step/1` matches
  `[Id, Tool | ChildForms]` where `Id` and `Tool` are bare atoms, so a step is
  written `(step s1 echo (args (value "hi")))`. The issue's `(msg ...)` example
  instead writes `(step (id s1) (tool echo) (args (value "hi")))` — id and tool
  wrapped in their own sub-forms. These are two different shapes for the same
  step map. The design has to bridge that gap (see Approach).

## Approach

Add a `(msg ...)` parse path that produces the exact envelope map the actor
already takes, and let `send/2` / `ask/3` treat a string or binary argument as
Lisp. Nothing inside the actor or the runtime changes — the Lisp is turned into
the existing `#{type, payload, steps?, llm?, correlation_id?}` map at the edge,
and from there the map path runs as it does today.

### Where the message form is parsed

`compile/2` dispatches on the top-level head. The reader returns the same flat
form list it does now. A new clause in `soma_lfe_parser` recognises a single
form headed by `msg` and routes it to message parsing; a form headed by `run`
still routes to `parse_run/1` and returns the pre-slice shape. So `compile/2`
returns either `{ok, #{run => ...}}` or `{ok, Envelope}` depending on the head,
and a non-`run`, non-`msg` head is still a diagnostic.

This keeps one entry point. The criteria assert the parse result, not the
function name, so a single `compile/2` that dispatches on the head is enough and
avoids a second public function that callers would have to choose between.

### How `(msg ...)` maps to the envelope

The `msg` form is a list of sub-forms. Each sub-form is a head atom plus a body:

- `(type chat)` → `type => chat` (bare symbol stays an atom). A string
  `(type "chat")` maps `type => <<"chat">>`. The actor treats `type` as opaque,
  so both are valid.
- `(payload "hi")` → `payload => <<"hi">>`. A flat string payload is the
  criteria's case. A nested `(payload (goal "..."))` is left out of this slice —
  the actor treats payload as opaque and the criteria only use the flat string,
  so the parser accepts a string, integer, or atom payload and rejects a nested
  form for now. This is a deliberate narrowing, not a limitation we're hiding;
  L.2/L.3 can widen it when a structured payload has a consumer.
- `(steps (step ...) (step ...))` → `steps => [StepMap]`, where each step map is
  the same shape `parse_run` produces today.
- `(correlation-id "c-1")` → `correlation_id => <<"c-1">>` (the atom key is
  rewritten from the hyphen form to the underscore form the actor reads).
- `(llm ...)` → `llm => LlmMap`, the sub-forms turned into a map the same way the
  envelope's other map fields are.

`steps`, `llm`, and `correlation-id` are optional. `type` and `payload` are
required — a `msg` missing either is a diagnostic, matching the actor's own
`missing_required_field` rule so the Lisp edge rejects the same envelopes the
map edge does.

### Step sub-forms inside `(msg ...)`

The issue's step shape `(step (id s1) (tool echo) (args ...))` wraps id and tool
in sub-forms, but the existing `parse_step/1` expects them positional. Rather
than change the v0.3 step grammar (which other tests pin) or force the message
grammar to use positional steps that don't match the issue, message-step parsing
accepts the wrapped `(id s1)` / `(tool echo)` sub-forms and produces the same
`#{id => s1, tool => echo, args => ...}` map. The `args` sub-form reuses the
existing arg-parsing shape. This is a new step reader local to the message path;
it does not touch `parse_run`'s positional step path, so criterion 4 (the `run`
form unchanged) holds by construction.

The trade-off: there are now two written forms for a step — positional under
`run`, wrapped under `msg`. That is a real inconsistency. It is the smaller cost
than either rewriting the v0.3 grammar (breaks merged tests, out of this slice's
scope) or contradicting the issue's own example. A later slice can unify them.

### Where the Lisp string is parsed for send/ask

In the client-side `send/2` and `ask/3` wrappers, before the `gen_statem:call`.
A map argument keeps the existing path untouched. A binary or string argument is
run through `soma_lfe:compile/2`:

- `{ok, Envelope}` → call the actor with that map, exactly as a map caller would.
- `{error, Diagnostics}` → return `{error, Diagnostics}` to the caller without
  ever calling the actor.

Parsing in the wrapper (not inside `idle/3`) keeps the actor's message contract
map-only — the actor never learns Lisp exists, which matches "Erlang at the
core". A malformed Lisp string is rejected before it reaches the actor, so the
actor process is never even touched on the malformed path, which makes the
"actor stays alive" criterion fall out for free.

## Acceptance criteria → tests

### Criterion 1 — `(msg ...)` with type/payload/steps parses to the hand-written envelope
- Call chain: none (direct parser call) — `soma_lfe:compile/2` →
  `soma_lfe_reader:read_forms/1` → `soma_lfe_parser` msg path
- Test entry: `soma_lfe:compile/2` (the public boundary)
- Test: `test_msg_form_produces_envelope_map` in
  `apps/soma_lfe/test/soma_lfe_message_tests.erl`

### Criterion 2 — `(msg ...)` with correlation-id and llm fills those envelope fields
- Call chain: none (direct parser call) — `soma_lfe:compile/2` → msg path
- Test entry: `soma_lfe:compile/2`
- Test: `test_msg_form_carries_correlation_id_and_llm` in
  `apps/soma_lfe/test/soma_lfe_message_tests.erl`

### Criterion 3 — malformed `(msg ...)` returns `{error, [Diagnostic]}`, no crash
- Call chain: none (direct parser call) — `soma_lfe:compile/2` → msg path
- Test entry: `soma_lfe:compile/2`
- Test: `test_malformed_msg_returns_diagnostics` in
  `apps/soma_lfe/test/soma_lfe_message_tests.erl` (one assertion for an unknown
  sub-form, one for a missing `type`/`payload`, each checking the diagnostic map
  carries `message` and `line`)

### Criterion 4 — top-level `(run ...)` still returns the pre-slice shape
- Call chain: none (direct parser call) — `soma_lfe:compile/2` →
  `soma_lfe_parser:parse_run/1`
- Test entry: `soma_lfe:compile/2`
- Test: `test_run_form_unchanged_after_msg_added` in
  `apps/soma_lfe/test/soma_lfe_message_tests.erl` (asserts the same
  `{ok, #{run => #{steps => Steps}}}` shape the v0.3 tests assert)

### Criterion 5 — Lisp `send/2` produces the same run outputs as the map `send/2`
- Call chain: `soma_actor:send/2` (binary arg) → `soma_lfe:compile/2` →
  `gen_statem:call` → `idle/3` `{send, Envelope}` → `maybe_start_run` →
  `soma_run_sup:start_run` → run terminal → `actor.task.completed`
- Test entry: `soma_actor:send/2` (the real entry point; no layer bypassed)
- Test: `test_lisp_send_matches_map_send_outputs` in
  `apps/soma_actor/test/soma_actor_lisp_message_SUITE.erl` (drives the same work
  twice — once with a `(msg ...)` string, once with the equivalent map — and
  asserts equal `get_task_result/2` outputs)

### Criterion 6 — Lisp `send/2` correlation chain matches the map `send/2` chain
- Call chain: `soma_actor:send/2` (binary arg) → `soma_lfe:compile/2` →
  `gen_statem:call` → `idle/3` → run → events into the store →
  `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2`
- Test: `test_lisp_send_correlation_chain_matches_map` in
  `apps/soma_actor/test/soma_actor_lisp_message_SUITE.erl` (drives both paths
  under a known correlation id and asserts the `by_correlation/2` event-type
  chains are equal)

### Criterion 7 — malformed Lisp `send/2` returns `{error, _}` and the actor survives
- Call chain: `soma_actor:send/2` (binary arg) → `soma_lfe:compile/2` returns
  `{error, _}` → wrapper returns without calling the actor
- Test entry: `soma_actor:send/2`
- Test: `test_malformed_lisp_send_actor_survives` in
  `apps/soma_actor/test/soma_actor_lisp_message_SUITE.erl` (sends a malformed
  string, asserts `{error, _}`, then sends a valid map to the same pid and
  asserts it is accepted and completes — proving the process stayed alive)

### Criterion 8 — Lisp `ask/3` returns the same result as the map `ask/3`
- Call chain: `soma_actor:ask/3` (binary arg) → `soma_lfe:compile/2` →
  `gen_statem:call` → `idle/3` `{ask, Envelope}` → run terminal → parked waiter
  reply
- Test entry: `soma_actor:ask/3` (the real entry point; no layer bypassed)
- Test: `test_lisp_ask_matches_map_ask_result` in
  `apps/soma_actor/test/soma_actor_lisp_message_SUITE.erl`

### Criterion 9 — a map envelope `send/2` still runs unchanged
- Call chain: `soma_actor:send/2` (map arg) → `gen_statem:call` → `idle/3`
  `{send, Envelope}` → run (no compile step on this path)
- Test entry: `soma_actor:send/2`
- Test: `test_map_send_path_untouched` in
  `apps/soma_actor/test/soma_actor_lisp_message_SUITE.erl` (a map envelope runs
  to `actor.task.completed`, never touching `soma_lfe`)

### Criterion 10 — `docs/contracts/` gains an L.1 entry mapping each proof to its case
- Call chain: none (direct source-file read)
- Test entry: none — this is the contract doc itself, written as part of the slice
- Test: `docs/contracts/L.1-test-contract.md`, a table mapping each criterion
  above to its suite and case (same format as `v0.3-test-contract.md`). The
  reviewer reads the file; there is no executable assertion.

## Risks & trade-offs

- **Two step grammars.** `run` keeps positional `(step s1 echo ...)`; `msg` uses
  wrapped `(step (id s1) (tool echo) ...)`. That is an inconsistency a reader
  will notice. The alternatives — rewrite the v0.3 grammar, or make the message
  grammar contradict the issue's example — are both worse for this slice. A
  follow-up can unify the two once both consumers exist.
- **Nested payload deferred.** Only a flat scalar payload is parsed; a nested
  `(payload (goal "..."))` is a diagnostic for now. The actor treats payload as
  opaque, so nothing downstream needs the structure yet, but a caller who writes
  a nested payload gets a parse error rather than a map. This is called out so
  L.2/L.3 can pick it up deliberately.
- **`type` as atom vs binary.** A bare `(type chat)` yields the atom `chat`; the
  existing map tests use a binary `<<"chat">>`. Both pass the actor's
  `maps:is_key(type, ...)` check, so behaviour is unaffected, but the Lisp and
  map forms can produce different `type` values for the "same" message. The
  criteria pin the atom form, so the parser produces an atom for a bare symbol
  and a binary for a quoted string, leaving the choice to the writer.
- **Dialyzer.** The slice touches `soma_lfe.erl`, `soma_lfe_parser.erl`, and
  `soma_actor.erl`. Pre-existing warnings in `soma_lfe_reader.erl` /
  `soma_tool_call.erl` are out of scope; the slice must not add a new warning to
  a file it touches. Run `rebar3 dialyzer` and report the result.

# L.4: term→Lisp renderer — Erlang terms render as Lisp s-exprs

## Current state

L.1–L.3 taught `soma_lfe` to parse Lisp into Erlang terms. The parse direction
is done: `soma_lfe_reader` scans text into raw forms, `soma_lfe_parser` walks
those into envelope / step / proposal maps. There is no inverse. Nothing in the
codebase turns an Erlang term back into Lisp text.

`soma_trace` (`apps/soma_event_store/src/soma_trace.erl`) renders a correlation
chain, but it renders to a flat one-line-per-event human string, not to Lisp.
`timeline/1` sorts events by timestamp ascending and emits `event_type
task_id=... step_id=... reason=...` lines. That format is readable but it is not
re-parseable and it drops most of each event's fields.

The wire protocol plan (`docs/lisp-messages.md`) wants the daemon's response to
be a Lisp s-expr, and wants the audit trace to speak Lisp. Both need a
term→Lisp renderer that does not exist yet. CLI.1's `soma_cli_server` already
has `jsonable/1` — the JSON-side precedent for the "render any term without
crashing" rule, including the fall-through clause that turns a pid/ref/fun into
a string. The Lisp renderer mirrors that rule on the Lisp side.

## Approach

Add a pure renderer `soma_lisp:render/1 -> iodata()`. It is the inverse of the
parse mapping:

- atom → symbol (bare, unquoted)
- binary → double-quoted string, with `"` and `\` escaped
- integer / float → the number's text
- list → `(elem elem ...)`
- map → a tagged form: each key/value becomes a `(key value)` pair, the whole
  thing wrapped so it reads back as a list of pairs

A map that has no natural head tag renders as `((k v) (k v) ...)` — a list of
pairs. The result form in criterion 1 carries a `result` head because the
renderer is asked to render it as a result; see the result/event shaping below.

A value with no s-expr form — pid, ref, fun, port — renders as a quoted string
through `io_lib:format("~p", [V])`, the same fall-through `jsonable/1` uses. The
renderer never crashes on an un-renderable value.

### Where the renderer lives — resolved

It goes in `apps/soma_event_store` as a new module `soma_lisp`, next to
`soma_trace`.

The open question weighed two homes. `soma_trace` needs the renderer now, and
CLI.1b's `cli_server` needs it next. `cli_server` is in `apps/soma_runtime`,
which already depends on `apps/soma_event_store`. So a renderer in
`soma_event_store` is reachable from both callers with no new dependency edge.

Putting it in `soma_lfe` would give parse/render symmetry in one module, but it
forces a new `soma_event_store → soma_lfe` edge. `soma_event_store` today
depends on `kernel, stdlib` only — it is the bottom of the app graph, and
keeping it there matters more than co-locating parse and render. The render
mapping is small and self-contained, so the symmetry argument is weak: the
renderer does not reuse any reader or parser code.

So: `soma_lisp:render/1` in `apps/soma_event_store/src/soma_lisp.erl`.
`soma_trace` gains `render_lisp/2` (fetch by correlation, then render each event
in timestamp order). The parse side stays in `soma_lfe`; the two directions live
in two apps and that is fine.

### Atom-to-symbol detail that the round-trip depends on

The parser maps the symbol `correlation-id` to the map key `correlation_id`
(hyphen in Lisp, underscore in the Erlang atom). For the round-trip criterion to
hold, the renderer's atom→symbol step has to undo that: an atom containing `_`
renders with `-` in the symbol text. Without this, rendering then re-parsing a
`(msg ...)` envelope would not produce a term equal to the original. The render
direction converts `_` to `-` on the way out; the parse direction already
converts `-` to `_` on the way in.

### Result and event shaping

Criterion 1 fixes the exact result form: `render/1` of the result map produces
`(result (status completed) (outputs ((s1 (value "hi")))) (correlation-id "c-7"))`.
The head symbol is `result`. Criterion 2 fixes the event form: an event map
renders to an s-expr whose sub-forms carry the event's fields. These are the two
shaped forms the renderer produces for known map shapes; a plain nested map
(like the `outputs` value) renders as the bare list-of-pairs form. The renderer
recognizes a result map and an event map by their keys and gives each the right
head; everything else falls to the generic map rendering.

Result and event forms are output-only — the issue's out-of-scope section says
so. Only `(msg …)` / `(run …)` need to round-trip, and those round-trip because
the renderer is the exact inverse of the parser for the term shapes those forms
parse into.

## Acceptance criteria → tests

### Criterion 1 — result map renders to the fixed s-expr
- Call chain: none (pure function, `soma_lisp:render/1` called directly)
- Test entry: `soma_lisp:render/1` with the result map literal
- Test: `test_render_result_map_produces_fixed_sexpr` in
  `apps/soma_event_store/test/soma_lisp_tests.erl`

### Criterion 2 — single event map renders carrying its fields
- Call chain: none (pure function, `soma_lisp:render/1` called directly)
- Test entry: `soma_lisp:render/1` with an event map
- Test: `test_render_event_map_carries_fields` in
  `apps/soma_event_store/test/soma_lisp_tests.erl`

### Criterion 3 — a pid renders as a quoted string, no crash
- Call chain: none (pure function, `soma_lisp:render/1` called directly)
- Test entry: `soma_lisp:render/1` with a term containing `self()`
- Test: `test_render_pid_becomes_quoted_string` in
  `apps/soma_event_store/test/soma_lisp_tests.erl`

### Criterion 4 — `soma_trace` renders a correlation chain as a Lisp trace, timestamp ascending, one s-expr per event
- Call chain: `soma_trace:render_lisp(Store, CorrelationId)` →
  `soma_event_store:by_correlation/2` → sort by timestamp → `soma_lisp:render/1`
  per event
- Test entry: `soma_trace:render_lisp/2` against a live event store seeded with
  events that carry out-of-order timestamps and one shared correlation_id
- Test: `test_render_lisp_orders_chain_by_timestamp` in
  `apps/soma_event_store/test/soma_trace_lisp_SUITE.erl`

### Criterion 5 — envelope term round-trips: parse → render → parse equals the original parsed term
- Call chain: `soma_lfe:compile/2` (parse) → `soma_lisp:render/1` →
  `soma_lfe:compile/2` (re-parse), comparing the two parsed terms
- Test entry: the test parses `(msg …)` with `soma_lfe:compile/2`, renders the
  term with `soma_lisp:render/1`, re-parses the rendered text, asserts equal.
  It enters at `soma_lfe:compile/2` because the criterion is about the renderer
  being the parser's inverse, so both directions are in the chain.
- Test: `test_msg_envelope_round_trips_through_render` in
  `apps/soma_event_store/test/soma_lisp_tests.erl`

### Criterion 6 — `docs/contracts/` gains an L.4 entry mapping each proof to its suite and case
- Call chain: none (direct source-file read)
- Test entry: the test reads `docs/contracts/L.4-test-contract.md` and asserts
  it names the L.4 suites and cases
- Test: `test_doc_names_l4_suites_and_cases` in
  `apps/soma_event_store/test/soma_l4_contract_doc_tests.erl`

### Criterion 7 — gate is green; L.4 tests open no real LLM call and no network socket
- Call chain: none (compile-time / source-level assertion)
- Test entry: a source-level guard reads the L.4 test sources and asserts no
  real-provider marker (`soma_llm_openai`, `api_key`, `base_url`, `http`,
  `https`, socket open) appears; the renderer is pure and touches neither
- Test: `test_no_real_provider_or_socket_in_l4_tests` in
  `apps/soma_event_store/test/soma_l4_mock_only_tests.erl`

## Risks & trade-offs

- The renderer in `soma_event_store` and the parser in `soma_lfe` are inverses
  that live in two apps. A future change to one mapping can drift from the
  other, and nothing but the round-trip test (criterion 5) catches it. That
  test only covers the `(msg …)` shape, so a drift in a shape it does not
  exercise would go unnoticed until CLI.1b or a later slice trips on it. The
  alternative — one module in `soma_lfe` — would have kept both directions in
  one place at the cost of a new dependency edge from the event store. We chose
  the clean graph and accept the round-trip test as the only guard against
  drift.

- The renderer guesses a map's head tag (`result`, an event form, or the bare
  pair list) from its keys. A map whose keys happen to look like a result or an
  event but is neither would get the wrong head. The criteria fix only the
  result and event shapes, so this is bounded for now, but the key-shape
  guessing is a soft spot if more shaped forms are added later.

- Rendering a pid to `"<0.123.0>"` text is lossy on purpose — it is for the
  audit trail, not for round-tripping. A pid in an event renders to a string and
  will never parse back into a pid. That matches `jsonable/1` and is fine
  because result/event forms are output-only.

# L.2: actor-to-actor Lisp — a Lisp (msg ...) body delivered between actors

## Current state

L.1 (#103) taught the `soma_actor:send/2` and `ask/3` wrappers to take a Lisp
`(msg …)` string. The string is compiled by `soma_lfe:compile/2` into the same
`#{type, payload, steps?, llm?, correlation_id?}` envelope map a caller could
have written by hand. The parse happens at the wrapper, before the actor process
is touched. The actor's internal contract stays map-only — it never learns Lisp
exists.

Actor-to-actor delivery is separate from that. When actor A's decision yields an
approved `actor_message` proposal, `execute_actor_message/5` in
`apps/soma_actor/src/soma_actor.erl` builds a delivery envelope from the proposal:

```erlang
To = maps:get(to, Proposal),
Payload = maps:get(payload, Proposal),
Delivery = #{type => <<"actor.message">>,
             payload => Payload,
             correlation_id => CorrelationId},
soma_actor:send(To, Delivery)
```

`Payload` here is whatever the `actor_message` proposal carried — in v0.5.6 it is
always a map (for example `#{text => <<"hello a2">>}`). The delivery is a map, so
it goes down the `is_map(Envelope)` clause of `send/2` and never reaches the Lisp
path. The sender's `correlation_id` is stamped onto the delivery wrapper, so the
receiver's task lands under the same id and `by_correlation/2` spans both actors.

What's missing: an `actor_message` body can only be a map. There is no way for A
to hand B a Lisp `(msg …)` string and have B parse and run it. The delivery
envelope has a fixed `actor.message` type and never carries `steps`, so even a
map body today does not drive a run on the receiver — it is just accepted.

## Approach

Parse the Lisp body **at the receiver**, by reusing the L.1 `send/2` Lisp path.
This is what `docs/lisp-messages.md` asks for — the receiver reuses
`soma_lfe:compile/2` rather than duplicating it.

The change is in `execute_actor_message/5`. Branch on the body's shape:

- Body is a **map**: build the `#{type, payload, correlation_id}` delivery exactly
  as today and call `soma_actor:send(To, Delivery)`. Byte-for-byte the v0.5.6 path.
- Body is a **Lisp string** (binary or iolist): hand it to `soma_actor:send(To, …)`
  as a string. `send/2`'s string clause compiles it through `soma_lfe:compile/2`
  into an envelope, then re-enters `send/2` with that envelope. The receiver runs
  the parsed envelope's steps through its normal `idle/3` dispatch.

The sender's `correlation_id` has to ride along so `by_correlation/2` still spans
both actors. A map delivery gets it from the wrapper field. A Lisp string does
not — the compiled envelope only carries a `correlation_id` if the body's text
included a `(correlation-id "…")` form, and we cannot count on the LLM (or a
hand-written proposal) to put one there. So the sender injects its own
`correlation_id` into the body before delivery. Two ways to do that, and the
design picks the second:

1. Parse the string in the sender, set `correlation_id` on the resulting map,
   deliver the map. This re-parses in the sender, which is the duplication the
   design note warns against, and it moves the parse off the receiver.
2. Keep the parse on the receiver. The sender appends a `(correlation-id "…")`
   form to the Lisp source carrying its own id, then delivers the string. The
   receiver's L.1 path parses the whole thing, correlation field included.

Option 2 keeps the single parse at the receiver and keeps the correlation story
identical to the map path (the sender's id wins). The cost is the sender editing
Lisp text. We confine that to a narrow, append-only step on a string we are about
to deliver, and `resolve_correlation_id/2` already honors a `correlation_id`
field over the task fallback, so an id the sender appends takes effect on the
receiver with no change to the receiver.

If the body string is malformed, `soma_lfe:compile/2` returns `{error, _}` on the
receiver and `send/2` returns `{error, Diagnostics}` — it does not crash and does
not call the receiver's actor process. `execute_actor_message/5` already wraps the
`send/2` call. A non-`ok` return from a Lisp delivery has to fail the **sender's**
task as data (status `failed`), the same shape a dead-receiver `exit` already
takes, so the sender stays alive. The receiver's actor pid is untouched by a
malformed body — the parse fails before the receiver process is reached — so it is
trivially still alive for the next message. The criterion that names "the
receiving actor's task in failed status" is met on the sender side: the sender is
the actor whose `actor_message` task fails when the body it delivers is
unparseable. (No receiver task is ever created for a malformed body, so there is
no receiver task to land in `failed`. The proof asserts the sender task fails and
both actor pids survive.)

The Erlang/OTP core is unchanged. Delivery, supervision, monitoring, and the
correlation chain all stay as in v0.5.6. Lisp is parsed only at the receiving
boundary, through the one `soma_lfe:compile/2` seam L.1 already established.

Files touched:

- `apps/soma_actor/src/soma_actor.erl` — `execute_actor_message/5` branches on
  map vs string body.
- `apps/soma_actor/test/soma_actor_lisp_to_lisp_SUITE.erl` — new CT suite, the
  L.2 actor-to-actor proofs.
- `docs/contracts/L.2-test-contract.md` — new contract doc.
- `apps/soma_tools/test/soma_l2_contract_doc_tests.erl` — new doc-check EUnit
  module (mirrors `soma_l1_contract_doc_tests`).

## Acceptance criteria → tests

### Criterion 1 — Lisp-bodied actor_message reaches the same terminal status as the map-bodied one
- Call chain: A1 mock returns approved `actor_message` whose body is a Lisp
  `(msg …)` string with steps → A1 `execute_actor_message/5` → `soma_actor:send/2`
  (string clause) → `soma_lfe:compile/2` → A2 `idle/3` accepts → A2
  `maybe_start_run/4` → `soma_run` terminal → A2 task status. The same test runs
  the equivalent map-bodied `actor_message` carrying the same steps and compares.
- Test entry: A1 `soma_actor:send/2` with a `proposal` mock directive (the real
  decision-to-delivery chain; no layer bypassed).
- Test: `lisp_body_reaches_same_terminal_status_as_map` in
  `apps/soma_actor/test/soma_actor_lisp_to_lisp_SUITE.erl`

### Criterion 2 — Lisp-bodied run produces the same step outputs as the map-bodied run
- Call chain: same chain as Criterion 1, run to A2's `run_completed` outputs.
  Both bodies carry one deterministic `echo` step over a fixed value, so the two
  receiver runs are directly comparable.
- Test entry: A1 `soma_actor:send/2` with a `proposal` mock directive.
- Test: `lisp_body_produces_same_step_outputs_as_map` in
  `apps/soma_actor/test/soma_actor_lisp_to_lisp_SUITE.erl`

### Criterion 3 — by_correlation/2 returns both actors' events for a Lisp body
- Call chain: A1 and A2 share one event store; the sender appends its
  `correlation_id` to the Lisp body before delivery, so A2's parsed task lands
  under A1's id → `soma_event_store:by_correlation/2` on A1's id returns both
  chains.
- Test entry: A1 `soma_actor:send/2` with a `proposal` mock directive, then a
  direct `soma_event_store:by_correlation/2` read (the assertion reads the store
  off the actor chain, which is the only place the spanning property is visible).
- Test: `by_correlation_spans_both_actors_for_lisp_body` in
  `apps/soma_actor/test/soma_actor_lisp_to_lisp_SUITE.erl`

### Criterion 4 — a malformed Lisp body leaves a terminal failed task, no crash
- Call chain: A1 mock returns approved `actor_message` whose body is a malformed
  Lisp string → A1 `execute_actor_message/5` → `soma_actor:send/2` (string clause)
  → `soma_lfe:compile/2` returns `{error, _}` → `send/2` returns `{error, _}` → A1
  fails its task as data.
- Test entry: A1 `soma_actor:send/2` with a `proposal` mock directive.
- Test: `malformed_lisp_body_marks_task_failed` in
  `apps/soma_actor/test/soma_actor_lisp_to_lisp_SUITE.erl`

### Criterion 5 — after a malformed body fails a task, the receiving actor accepts a following valid message
- Call chain: the Criterion 4 chain, then a second valid map-bodied `actor_message`
  delivered to the same A2 → A2 `idle/3` accepts → terminal.
- Test entry: A1 `soma_actor:send/2` with a `proposal` mock directive, twice; an
  `is_process_alive/1` check on A2 between them.
- Test: `actor_alive_and_accepts_after_malformed_body` in
  `apps/soma_actor/test/soma_actor_lisp_to_lisp_SUITE.erl`

### Criterion 6 — a map-bodied actor_message still delivers and runs (v0.5.6 untouched)
- Call chain: A1 mock returns approved `actor_message` with a map body → A1
  `execute_actor_message/5` (map branch, byte-for-byte the v0.5.6 build) →
  `soma_actor:send/2` (map clause, never touching `soma_lfe`) → A2 `idle/3`
  accepts → terminal.
- Test entry: A1 `soma_actor:send/2` with a `proposal` mock directive.
- Test: `map_body_path_unchanged` in
  `apps/soma_actor/test/soma_actor_lisp_to_lisp_SUITE.erl`

### Criterion 7 — docs/contracts/ gains an L.2 entry mapping each proof to its suite and case
- Call chain: none (direct source-file read). The EUnit test reads
  `docs/contracts/L.2-test-contract.md` and asserts it names the suite and every
  case, mirroring `soma_l1_contract_doc_tests`.
- Test entry: `file:read_file/1` on the contract doc.
- Test: `test_doc_names_lisp_to_lisp_suite_and_cases` in
  `apps/soma_tools/test/soma_l2_contract_doc_tests.erl`

### Criterion 8 — rebar3 eunit && rebar3 ct passes
- Call chain: none (the full gate). Met when every suite above is green together
  with the existing 154 EUnit / 198 CT.
- Test entry: the merge gate (`rebar3 eunit && rebar3 ct`).
- Test: the whole suite — no single new case.

### Criterion 9 — the L.2 test run opens no real LLM call and no external network socket
- Call chain: none (property of the test setup). Every L.2 proof drives A1 with a
  `#{directive => proposal, output => …}` mock directive — the same mock the v0.5
  and L.1 suites use — and the `proposal` directive returns a pre-built proposal
  without `perform_call/1` reaching `soma_llm_openai`. No opt of any L.2 test
  carries a real-provider config.
- Test entry: the mock seam (`soma_llm_call:perform_call/1`), asserted by the
  absence of a real-provider opt in every L.2 test's setup.
- Test: enforced by construction across `soma_actor_lisp_to_lisp_SUITE`; no
  dedicated case.

## Risks & trade-offs

The sender editing the Lisp body to append `(correlation-id "…")` means the
sender is now producing Lisp text, not only consuming it. The append is narrow —
one form, on a string the sender is about to deliver — but it is string surgery,
and a body that already carried its own `(correlation-id …)` would end up with two.
`(msg …)` parsing takes the last `correlation-id` field it sees
(`parse_msg_fields` folds left to right into the map), so an appended id wins over
an earlier one, which is the behaviour we want — the sender's id should override.
If that fold order ever changes, this breaks quietly. The alternative — parse in
the sender, set the field on the map, deliver the map — avoids the string surgery
but re-parses in the sender and moves the parse off the receiver, against the
design note. We take the append and pin the precedence with a test.

"The receiving actor's task in failed status" for a malformed body is satisfied on
the **sender** side, because a malformed body never creates a receiver task — the
parse fails at the sender's `send/2` call before the receiver process is reached.
The criterion's intent (a malformed body fails as data, no crash, actor survives)
holds; the task that lands in `failed` is the sender's `actor_message` task. The
proof asserts exactly that and checks both pids survive, rather than asserting a
receiver task that does not exist.

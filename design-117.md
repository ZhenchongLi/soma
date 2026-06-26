# L.5: Lisp self-repair — the LLM fixes a malformed Lisp proposal, bounded + re-validated

## Current state

When the mock LLM returns a Lisp proposal string, the worker hands it back
verbatim and the actor parses it actor-side. `proposal_result/2` in
`soma_actor.erl` runs `soma_lfe:compile/2` on a `proposal`-directive binary
output (line 871). A parse failure returns `{invalid_proposal, Diagnostics}`.
The caller — the `{invalid_proposal, Diagnostics}` branch of the `llm_result`
clause in `idle/3` (line 434) — records the task `failed` with the diagnostics
as the reason, emits `actor.task.failed`, releases any parked waiter, and the
actor stays alive.

That is a dead end. A proposal that is one paren away from valid is thrown away
even though the actor already has an LLM that could fix it. The whole L.* track
treats Lisp as the language agents speak; an LLM that speaks imperfect Lisp is
the expected case, not the exceptional one. `docs/lisp-messages.md` ("Self-repair
(L.5)") calls for one bounded repair loop here.

Today's actor also has no notion of a repair mode or a repair-attempt counter.
The per-task budget exists (`budget = #{max_llm_calls, max_steps}` in `#data`,
counted in `llm_call_counts`), but a repair call is a new LLM call that must be
counted against `max_llm_calls`, and that wiring does not exist yet.

## Approach

Turn the `{invalid_proposal, Diagnostics}` branch into the entry of a bounded
repair loop. The loop lives in the actor, error-path only. A valid proposal
never reaches it.

Decisions:

- **Repair is on by default.** The doc says default-on under the single-user
  trusted scope. The `start_actor` opt that turns it off is `repair => strict`.
  Absent, or `repair => auto`, means repair runs. `repair => strict` means a
  malformed proposal fails immediately, the way it does today. The opt is stored
  on `#data` as a new `repair` field.

- **The attempt cap is a separate opt: `max_repairs => N` on the `start_actor`
  opts, defaulting to a small constant (1).** It bounds how many repair calls one
  task may make. It is distinct from `max_llm_calls`: `max_repairs` bounds the
  repair loop's length, `max_llm_calls` bounds total LLM calls for the task. A
  repair attempt has to pass both. The per-task repair count rides on the task
  map (a new `repair_count` key), reset per task.

- **The repaired output re-enters the full pipeline.** A repair call is just
  another `soma_llm_call` the actor owns. Its `{llm_result, ...}` lands in the
  same `idle/3` clause and runs the same `proposal_result/2` →
  `soma_proposal:normalize/1` → `soma_policy:check/2` → budget → execute chain.
  The loop does not parse-and-inject a proposal on a side path; it re-enters the
  one path. That is the safety crux from the doc: repair is a second chance to
  become valid, never a bypass of policy or budget.

- **Each repair call counts as one LLM call.** The repair call goes through
  `start_llm_call/4`, which increments `llm_call_counts`. So a repair attempt
  that would push the count past `max_llm_calls` is refused by the existing
  `llm_budget_available/2` check before the worker starts, and the task fails
  `{budget_exceeded, max_llm_calls}` — no new budget code, the repair call reuses
  the existing spend point.

- **How the mock supplies the repaired s-expr.** The malformed `proposal`
  directive's `llm` map carries an extra field naming what the repair call should
  return — `repair_output => <RepairedLispOrMap>`. When the actor starts the
  repair call, it builds a fresh `llm` map whose `output` is that `repair_output`
  (still the `proposal` directive, still mock-only, still no socket). To drive the
  "every repair stays malformed" case, `repair_output` is itself malformed Lisp,
  so each repair call returns malformed source again. This keeps the mock wiring
  in the test's `llm` map and asserts only on the loop's observable behaviour, as
  the issue allows.

- **The `proposal.repaired` event** fires at the point a repaired form re-parses
  successfully — when a repair call's output makes it through `soma_lfe:compile/2`
  and `soma_proposal:normalize/1`. It carries the task's `task_id` and
  `correlation_id`. It marks "a previously malformed proposal was repaired and is
  now a valid proposal", distinct from `proposal.created`. To know a given
  `llm_result` is a repair result (not the first call), the actor flags the
  repair call's task entry (`repair_in_flight => true` or the `repair_count`
  already being above zero), set when the repair call starts and read in the
  `{proposal, _}` branch.

The loop, restated against the code:

```
proposal_result/2 -> {invalid_proposal, Diagnostics}
  repair strict?            -> fail now (today's behaviour)
  repair auto, count < max_repairs, llm budget left?
        -> start_llm_call with repair_output as the next output (count++)
           that call's result re-enters proposal_result/2:
             {proposal, _}        -> proposal.repaired, then normalize/policy/budget/execute
             {invalid_proposal, _} and count == max_repairs -> fail with diagnostics
             {invalid_proposal, _} and count <  max_repairs -> repair again
  llm budget would be exceeded -> fail {budget_exceeded, max_llm_calls}
```

No new state machine state. The repair call is an ordinary owned LLM call; the
existing `llm_result` / monitor / timeout clauses already handle its lifecycle.

## Acceptance criteria → tests

### Criterion 1 — repaired `(reply ...)` reaches `completed` like a directly-valid reply
- Call chain: `soma_actor:send/2` → `idle/3` `{send}` → `maybe_start_llm_call/4`
  → `start_llm_call/4` → first `llm_result` → `proposal_result/2`
  `{invalid_proposal, _}` → repair `start_llm_call/4` → second `llm_result` →
  `proposal_result/2` `{proposal, _}` → `soma_policy:check/2` → toolless complete
- Test entry: `soma_actor:send/2` (full chain, no layer bypassed)
- Test: `repaired_reply_reaches_same_terminal_result_as_valid_reply` in
  `apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl`

### Criterion 2 — a successful repair emits `proposal.repaired` with task_id + correlation_id
- Call chain: same as Criterion 1 up to the second `llm_result` →
  `proposal_result/2` `{proposal, _}` branch → `proposal.repaired` emit
- Test entry: `soma_actor:send/2`; the event is read back through
  `soma_event_store:by_correlation/2`
- Test: `successful_repair_emits_proposal_repaired_with_ids` in
  `apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl`

### Criterion 3 — a repaired `run_steps` with a disallowed tool reaches `rejected`
- Call chain: `soma_actor:send/2` → first `llm_result` `{invalid_proposal, _}`
  → repair call → second `llm_result` `{proposal, run_steps}` →
  `soma_policy:check/2` `{reject, _}` → `rejected` + `proposal.rejected`
- Test entry: `soma_actor:send/2` (the policy gate runs on the repaired form, so
  no layer is skipped)
- Test: `repaired_run_steps_outside_allowlist_is_rejected` in
  `apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl`

### Criterion 4 — every repair stays malformed, task fails after max attempts with diagnostics
- Call chain: `soma_actor:send/2` → first `llm_result` `{invalid_proposal, _}`
  → repair `start_llm_call/4` → repair `llm_result` `{invalid_proposal, _}` →
  (loop until `repair_count == max_repairs`) → `actor.task.failed` with the parse
  diagnostics as reason
- Test entry: `soma_actor:send/2`; the failure reason is read through
  `soma_actor:get_task_status/2`
- Test: `all_repairs_malformed_fails_after_max_attempts_with_diagnostics` in
  `apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl`

### Criterion 5 — after a bounded repair failure the actor takes a following valid message
- Call chain: the Criterion 4 chain to terminal `failed`, then a second
  `soma_actor:send/2` with a valid `(reply ...)` proposal → `idle/3` →
  `start_llm_call/4` → `llm_result` `{proposal, _}` → complete
- Test entry: `soma_actor:send/2` twice on the same live actor; the second
  task's status is read through `get_task_status/2`
- Test: `actor_alive_after_repair_failure_runs_next_valid_message` in
  `apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl`

### Criterion 6 — a repair attempt that would exceed `max_llm_calls` is not made
- Call chain: `soma_actor:send/2` (actor started with
  `budget => #{max_llm_calls => 1}`) → first `llm_result`
  `{invalid_proposal, _}` → repair entry → `llm_budget_available/2` is false →
  `fail_task/3` with `{budget_exceeded, max_llm_calls}`, no repair worker started
- Test entry: `soma_actor:send/2`; the failure reason is read through
  `get_task_status/2`, and the absence of a second `llm.started` is read through
  `by_correlation/2`
- Test: `repair_blocked_by_max_llm_calls_fails_budget_exceeded` in
  `apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl`

### Criterion 7 — `strict` mode fails malformed Lisp immediately, no repair call, no `proposal.repaired`
- Call chain: `soma_actor:send/2` (actor started `repair => strict`) → first
  `llm_result` `{invalid_proposal, _}` → strict branch → `actor.task.failed`,
  no second `start_llm_call/4`
- Test entry: `soma_actor:send/2`; the event trail is read through
  `by_correlation/2` and asserted to carry exactly one `llm.started` and no
  `proposal.repaired`
- Test: `strict_mode_fails_malformed_without_repair_call` in
  `apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl`

### Criterion 8 — a valid Lisp proposal completes with one `llm.started` and no `proposal.repaired`
- Call chain: `soma_actor:send/2` → `start_llm_call/4` → `llm_result`
  `{proposal, _}` → `proposal.created` → complete (the repair branch never runs)
- Test entry: `soma_actor:send/2`; the event trail is read through
  `by_correlation/2`
- Test: `valid_proposal_completes_with_one_llm_started_no_repair` in
  `apps/soma_actor/test/soma_actor_lisp_repair_SUITE.erl`

### Criterion 9 — `docs/contracts/` gains an L.5 entry mapping each proof to its suite and case
- Call chain: none (direct source-file read)
- Test entry: the test reads `docs/contracts/L.5-test-contract.md` and asserts it
  names the L.5 suite and each case
- Test: `test_doc_names_l5_suites_and_cases` in
  `apps/soma_actor/test/soma_l5_contract_doc_tests.erl`

### Criterion 10 — the L.5 suite opens no real LLM call or network socket
- Call chain: none (direct source-file read)
- Test entry: the test reads the L.5 suite source and asserts every `directive =>`
  is `directive => proposal` and no real-provider marker
  (`soma_llm_openai`, `api_key`, `base_url`, `api_base`, `http`, `https`) appears
- Test: `test_every_llm_directive_is_the_proposal_mock` and
  `test_no_real_provider_config_in_suite` in
  `apps/soma_actor/test/soma_l5_mock_only_tests.erl`

## Risks & trade-offs

- **The mock-wiring field (`repair_output`) leaks a test-only key into the `llm`
  map.** It is read only on the repair path and ignored otherwise, so it costs the
  happy path nothing, but it is a mock contract the test depends on, not a real
  provider's shape. Node B's real repair call will build the repair prompt from
  the source plus diagnostics and ignore `repair_output` entirely. The design
  accepts this because the issue's open question explicitly leaves the mock-wiring
  shape to the architect and asserts only on observable behaviour.

- **`max_repairs` defaults to 1.** One repair attempt is the smallest bound that
  still proves the loop. A higher default would make the "all repairs malformed"
  case slower and the budget interaction harder to read. If real use wants more
  attempts, it is one opt away; the criteria are written against "the configured
  maximum", not a fixed number, so a different default does not break them.

- **Distinguishing a repair result from a first-call result rides on task-map
  state (`repair_count` / a repair flag).** If that flag is set but cleared on the
  wrong branch, a first-call success could wrongly emit `proposal.repaired`, or a
  repair success could miss it. Criterion 8 (valid proposal, no `proposal.repaired`)
  and Criterion 2 (repaired form, exactly one `proposal.repaired`) together pin
  both directions, so the flag's handling is covered.

- **The repair call reuses the LLM timeout/monitor machinery unchanged.** A repair
  call that hangs or crashes is handled by the existing `llm_timeout` and `'DOWN'`
  clauses, which mark the task failed. L.5 adds no new failure mode there; it
  inherits the v0.5 ones. This is in scope only insofar as the repair call is an
  ordinary owned call — the issue's criteria do not ask for a repair-specific
  timeout proof, and none is added.

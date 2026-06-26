# L.3: Lisp proposals — mock LLM emits a Lisp s-expr proposal map

## Current state

The mock `soma_llm_call:perform_call/1` has a `proposal` directive. It returns
the raw map carried under `output` verbatim — no proposal logic in the worker.
The actor's `idle/3` `{llm_result, ..., {ok, Output}}` clause runs that output
through `proposal_result/1`. That function only knows two shapes: a map with a
`kind` key (run it through `soma_proposal:normalize/1`, tag `{proposal, _}` or
`{invalid_proposal, _}`) and anything else (tag `{opaque, _}`, store verbatim).
From there the existing pipeline runs: `proposal.created` → `soma_policy:check/2`
→ `proposal.approved`/`proposal.rejected` → execute or complete.

So today the LLM speaks maps. L.1 and L.2 already moved the message envelope and
actor-to-actor bodies to Lisp, parsed at the boundary by `soma_lfe:compile/2`.
The proposal is the last piece still map-only.

`soma_lfe:compile/2` dispatches on the top-level head: a single `(msg ...)` form
goes to `soma_lfe_parser:parse_msg/1`, everything else to `parse_run/1`. There is
no proposal path. The L.1 step grammar (`(step (id ..) (tool ..) (args ..))`,
`(from-step ..)`) lives in `soma_lfe_parser` and is reusable as-is.

## Approach

Two changes, both additive.

First, `soma_lfe` learns to parse proposal forms. `dispatch/1` gains five heads —
`(reply ...)`, `(run-steps ...)`, `(reject ...)`, `(ask ...)`,
`(actor-message ...)` — each routing to a new `soma_lfe_parser:parse_proposal/1`.
The parser turns each form into the exact `#{kind => ...}` map
`soma_proposal:normalize/1` already accepts:

- `(reply (text "hi"))` → `#{kind => reply, text => <<"hi">>}`
- `(run-steps (step ...) ...)` → `#{kind => run_steps, steps => [StepMap, ...]}`,
  reusing the L.1 step parser so the step maps are identical to the run path.
- `(reject (reason "..."))` → `#{kind => reject, reason => <<"...">>}`
- `(ask (question "..."))` → `#{kind => ask, question => <<"...">>}`
- `(actor-message (to "...") (payload ...))` →
  `#{kind => actor_message, to => <<"...">>, payload => ...}`

A malformed proposal form returns `{error, [Diagnostic]}` with `message` and
`line`, the same shape `parse_msg`/`parse_run` already produce. No crash.

Second, the actor's `proposal_result/1` learns to accept a string output. When
the mock's `output` is a binary or string (not a map), the actor runs it through
`soma_lfe:compile/2`:

- compile returns `{ok, ProposalMap}` → feed that map into the existing
  `soma_proposal:normalize/1` path, exactly as a raw map would. Approve, gate,
  execute, complete — all unchanged.
- compile returns `{error, Diagnostics}` → tag `{invalid_proposal, Diagnostics}`,
  the same tag a failed `normalize/1` already produces, so the actor records the
  task `failed` with the diagnostics as data and stays alive. This reuses the
  existing `{invalid_proposal, _}` handling clause in `idle/3` with no new branch.

Why hook the Lisp parse in `proposal_result/1` and not in the mock worker: the
worker is the provider seam. Keeping it returning `output` verbatim means a real
provider that emits Lisp (node B) drops into the same actor-side parse with no
worker change. The boundary stays "Lisp parsed at the edge into a map", matching
L.1/L.2.

Why a string output is unambiguous: the v0.5 contract says `proposal` returns its
`output` verbatim and the map path keys on `is_map(Output)`. A binary/string
output never collided with the map path before, so routing it to the Lisp parser
adds a path rather than changing one. The `opaque` tag still catches any other
non-map output.

`(reject ...)`, `(ask ...)`, and `(actor-message ...)` parse forms ship for
grammar completeness. The end-to-end criteria only exercise `reply` and
`run-steps`, which need no pid binding. A Lisp `actor-message` names its target
with a string but `soma_proposal:normalize/1` wants a pid `to`, so it will not
normalize as written — see Risks.

## Acceptance criteria → tests

### Criterion 1 — `(reply (text "hi"))` parses to a reply proposal map
- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe:dispatch/1` → `soma_lfe_parser:parse_proposal/1`, then the test feeds
  the result map to `soma_proposal:normalize/1`
- Test entry: `soma_lfe:compile/2` (the real parser boundary; no layer bypassed)
- Test: `test_reply_form_normalizes_to_reply_kind` in
  `apps/soma_lfe/test/soma_lfe_proposal_tests.erl`

### Criterion 2 — `(run-steps (step ...))` parses to a run_steps proposal map
- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe:dispatch/1` → `soma_lfe_parser:parse_proposal/1` (reusing the L.1 step
  parser), then the test feeds the result to `soma_proposal:normalize/1`
- Test entry: `soma_lfe:compile/2`
- Test: `test_run_steps_form_normalizes_with_equivalent_steps` in
  `apps/soma_lfe/test/soma_lfe_proposal_tests.erl`

### Criterion 3 — a malformed proposal form returns a diagnostic, no crash
- Call chain: `soma_lfe:compile/2` → `soma_lfe_reader:read_forms/1` →
  `soma_lfe:dispatch/1` → `soma_lfe_parser:parse_proposal/1`
- Test entry: `soma_lfe:compile/2`
- Test: `test_malformed_proposal_form_returns_diagnostic` in
  `apps/soma_lfe/test/soma_lfe_proposal_tests.erl`

### Criterion 4 — a mock Lisp `(reply ...)` reaches the same terminal result as the map reply
- Call chain: `soma_actor:send/2` → `gen_statem:call` → `idle/3` start →
  `soma_llm_call:start/1` → `perform_call/1` (`proposal` directive, Lisp string
  output) → `{llm_result, {ok, LispString}}` back to `idle/3` →
  `proposal_result/1` → `soma_lfe:compile/2` → `soma_proposal:normalize/1` →
  `soma_policy:check/2` → task `completed`
- Test entry: `soma_actor:send/2` (the full decision chain, no layer bypassed,
  mock LLM only)
- Test: `lisp_reply_reaches_same_terminal_result_as_map_reply` in
  `apps/soma_actor/test/soma_actor_lisp_proposal_SUITE.erl`

### Criterion 5 — a mock Lisp `(run-steps ...)` emits `proposal.executed` and runs
- Call chain: `soma_actor:send/2` → `idle/3` → `soma_llm_call` `proposal`
  directive (Lisp string) → `proposal_result/1` → `soma_lfe:compile/2` →
  `soma_proposal:normalize/1` → `soma_policy:check/2` `allow` →
  `execute_run_steps/6` (emits `proposal.executed`) → `soma_run` terminal →
  task `completed`
- Test entry: `soma_actor:send/2`; outcome read back through
  `soma_event_store:by_correlation/2` and `get_task_result/2`
- Test: `lisp_run_steps_emits_proposal_executed_and_runs` in
  `apps/soma_actor/test/soma_actor_lisp_proposal_SUITE.erl`

### Criterion 6 — a malformed Lisp proposal fails the task as data, actor stays alive
- Call chain: `soma_actor:send/2` → `idle/3` → `soma_llm_call` `proposal`
  directive (malformed Lisp string) → `proposal_result/1` → `soma_lfe:compile/2`
  returns `{error, Diags}` → `{invalid_proposal, Diags}` → task `failed`; then a
  second `soma_actor:send/2` with a valid message is accepted
- Test entry: `soma_actor:send/2`
- Test: `malformed_lisp_proposal_fails_task_actor_alive` in
  `apps/soma_actor/test/soma_actor_lisp_proposal_SUITE.erl`

### Criterion 7 — the v0.5 raw-map proposal path is unchanged
- Call chain: `soma_actor:send/2` → `idle/3` → `soma_llm_call` `proposal`
  directive (a map output) → `proposal_result/1` `is_map` clause →
  `soma_proposal:normalize/1` → `soma_policy:check/2` → execute, never touching
  `soma_lfe`
- Test entry: `soma_actor:send/2`
- Test: `map_proposal_path_unchanged` in
  `apps/soma_actor/test/soma_actor_lisp_proposal_SUITE.erl`

### Criterion 8 — `docs/contracts/` gains an L.3 entry mapping each proof
- Call chain: none (direct source-file read)
- Test entry: the test reads `docs/contracts/L.3-test-contract.md` and asserts it
  names each suite and case above
- Test: `test_doc_names_l3_suites_and_cases` in
  `apps/soma_tools/test/soma_l3_contract_doc_tests.erl`

### Criterion 9 — `rebar3 eunit && rebar3 ct` green, no real LLM or network socket
- Call chain: none (compile-time / source assertion). The L.3 actor suite drives
  the mock `proposal` directive only; this guard pins that against the suite
  source the same way `soma_l2_mock_only_tests` does for L.2.
- Test entry: the test reads `apps/soma_actor/test/soma_actor_lisp_proposal_SUITE.erl`
  and asserts every `directive =>` is `directive => proposal` and no real-provider
  marker (`soma_llm_openai`, `api_key`, `base_url`, `http`, `https`) appears
- Test: `test_every_llm_directive_is_the_proposal_mock` and
  `test_no_real_provider_config_in_suite` in
  `apps/soma_actor/test/soma_l3_mock_only_tests.erl`

## Risks & trade-offs

A Lisp `(actor-message (to "...") ...)` parses to a map with a string `to`, but
`soma_proposal:normalize/1` requires a pid `to` and will reject it. So the parse
form ships but cannot drive an end-to-end actor-message task. This is a known gap,
flagged in the issue's open question, and left for a later slice that decides how
a Lisp message names a live actor. L.3 only ships the parse forms for `reject`,
`ask`, and `actor-message` so the grammar is complete; the executing criteria
cover only `reply` and `run-steps`.

Routing a string output to the Lisp parser rests on the v0.5 invariant that the
`proposal` directive's output was always a map. If a future directive returns a
plain string meant to stay opaque, it would now be parsed as Lisp and likely fail.
Today no such directive exists, and the `opaque` tag still covers any non-map,
non-string output, so the surface is the string case alone. Worth a comment at the
`proposal_result/1` string clause noting the assumption.

A malformed Lisp proposal becomes a clean task `failed`, not a repair attempt.
That is intentional — the parse-error → LLM-repair → re-parse loop is L.5, out of
scope here.

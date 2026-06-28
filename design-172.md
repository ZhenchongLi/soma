# node B.3: planning mode — real model emits a (run-steps …) Lisp plan that executes

## Current state

The real provider works for one shape: a text answer. `soma_llm_openai:parse_response/1` (soma_llm_openai.erl:44) pulls `choices[0].message.content` out of the chat response and always returns `{ok, #{kind => reply, text => Content}}`. There is no other return shape. A model that wrote a `(run-steps …)` plan into its content would still come back tagged `reply`.

On the actor side the worker result lands in `idle(info, {llm_result, …, {ok, Output}}, Data)` (soma_actor.erl:309), which hands `Output` to `proposal_result/2` (soma_actor.erl:966). That function decides how to read the output:

- `Output` is a map carrying a `kind` key → normalize it as a proposal (the `is_map` clause, soma_actor.erl:966).
- `Output` is a binary/string **and** the task's directive is `proposal` → parse it as Lisp through `soma_lfe:compile/2`, then normalize (soma_actor.erl:983).
- anything else → opaque (soma_actor.erl:993).

The real provider's output is `#{kind => reply, text => Content}` — a map with a `kind`. So it hits the first clause and normalizes straight to a `reply`. The Lisp-parse clause is gated on the `proposal` directive, and the real-provider call carries no directive (`llm_directive` is `undefined`). So today the model's `(run-steps …)` content reaches `soma_proposal:normalize/1` as a reply's `text`, never `soma_lfe:compile/2`. That is the gap.

The Lisp-parse-then-run machinery downstream is already built and proven for the mock: `soma_actor_lisp_proposal_SUITE` drives a `(run-steps …)` string through `proposal_result/2` → `soma_lfe:compile/2` → `soma_proposal:normalize/1` → `soma_policy:check/2` → an owned `soma_run`, and the malformed case lands on the bounded-repair / terminal-failed path (soma_actor.erl:455). None of that needs to change. The only missing piece is making the real provider's content reach that Lisp parse.

Two more facts shape the work:

- `build_call_opts/2` (soma_actor.erl:827) takes `model_config` and the envelope only. It builds one user message from the payload prompt. It has no system message and no access to the tool policy.
- The tool names live in the actor's `tool_policy` (`#{allowed_tools => [atom()] | all}`), held on the `#data` record (soma_actor.erl:102). The builder can't see it today.

## Approach

Planning mode is a flag on the actor's `model_config` (`#{plan => true}`), alongside the existing `provider => openai_compat` routing that already lives there. That answers the first open question: the toggle sits where the real-provider routing already sits, so `build_call_opts/2` and the result handler can both read it from `model_config` without a new envelope shape. When the flag is off or absent, every path stays byte-for-byte the B.1/B.2 reply behaviour.

Two changes, both actor-side. `soma_llm_openai` stays reply-only and never imports `soma_lfe`.

**1. The request carries a planning system prompt.** When `model_config` has `plan => true`, `build_call_opts/2` prepends a system message ahead of the user message. The system message instructs the model to answer with a `(run-steps …)` plan, and lists the allowed tool names. The names come from the actor's `tool_policy`, so the builder needs the policy threaded in. That answers the second open question: I read "the allowed tools" as the policy's `allowed_tools` names. `build_call_opts/2` gains a parameter (or the policy is passed in the opts it already receives) so it can read those names. An `all` policy has no concrete names — the system message still carries the `(run-steps …)` instruction text, just without a tool list, which is what the criterion asks for.

The builder stays pure. The system prompt is plain text built from the tool-name list; no call, no event.

**2. The model's content is parsed as a plan, not stored as a reply.** When the call was a planning call, the actor reads the provider's reply text as a Lisp plan. The provider still returns `#{kind => reply, text => Content}` — we do not change the provider. The actor, knowing the task was a planning task, takes `Content` and runs it through the same Lisp-parse-then-normalize path the mock `proposal` directive already uses (`soma_lfe:compile/2` → `soma_proposal:normalize/1`). A well-formed `(run-steps …)` becomes a `run_steps` proposal; the existing decision loop (policy → owned `soma_run` → `proposal.executed` → `run.completed`) runs it with no change. A malformed plan returns `{error, Diags}` from compile, which `proposal_result/2` already tags `{invalid_proposal, Diags}`, which already drives the bounded-repair-or-terminal-failed path.

The cleanest way to mark "this was a planning call" is to stamp the task with a planning flag when the call starts (the same place `llm_directive` is stamped, soma_actor.erl:946), then have the result handler route a planning task's reply content through the Lisp parse. This reuses the existing directive-shaped seam in `proposal_result/2` rather than adding a parallel one: a planning task's `{ok, #{kind => reply, text => Content}}` is unwrapped to `Content` and parsed as Lisp, exactly as the mock `proposal` directive's binary output is.

Off-path (no `plan` flag): `build_call_opts/2` builds the one user message it builds today, the result handler normalizes the `reply` map as it does today. Nothing moves.

## Acceptance criteria → tests

### Criterion 1 — a planning-mode real response runs a plan end to end
- Call chain: `soma_actor:send/2` → `idle/3` llm-call path → `build_call_opts/2` (planning system prompt, fixed `response` seam) → `soma_llm_call:start/1` → `soma_llm_openai:chat/1` (parses the fixed `{200, Body}`, no socket) → `idle(info, {llm_result, …})` → `proposal_result/2` (planning task → `soma_lfe:compile/2` → `soma_proposal:normalize/1`) → `soma_policy:check/2` → `execute_run_steps/6` → owned `soma_run` → `run.completed`
- Test entry: `soma_actor:send/2` (no layer bypassed; the fixed `response` is the no-socket seam B.1 already uses, not a skipped layer)
- Test: `planning_mode_real_response_runs_plan_to_completion` in `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl`

### Criterion 2 — the planning request carries a (run-steps …) system message over the allowed tools
- Call chain: `soma_actor:build_call_opts/2` with a planning `model_config` and the allowed-tools list
- Test entry: `build_call_opts/2` directly (pure builder; an end-to-end run would not let the test inspect the message list the provider receives, so the test reads the built opts at the builder)
- Test: `test_planning_mode_builds_run_steps_system_message_over_allowed_tools` in `apps/soma_actor/test/soma_actor_call_opts_tests.erl`

### Criterion 3 — a malformed plan fails the task as data, actor survives
- Call chain: `soma_actor:send/2` → planning llm-call path → fixed `response` whose content is a malformed Lisp plan → `proposal_result/2` (`soma_lfe:compile/2` returns `{error, Diags}` → `{invalid_proposal, Diags}`) → `maybe_repair/5` → terminal `failed`; then a second `soma_actor:send/2` reaches a normal terminal result
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `planning_mode_malformed_plan_fails_task_actor_alive` in `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl`

### Criterion 4 — planning off still yields a reply proposal carrying the response text
- Call chain: `soma_actor:send/2` → llm-call path with a non-planning real-provider `model_config` → `soma_llm_openai:chat/1` (fixed `response`) → `proposal_result/2` (`is_map` clause, normalize as reply) → terminal `completed`
- Test entry: `soma_actor:send/2` (no layer bypassed)
- Test: `planning_mode_off_yields_reply_proposal_unchanged` in `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl`
- Note: the existing `real_provider_actor_completes_llm_task_through_openai_no_socket` already proves the off path for a `model_config` with no `plan` key; this added case pins that the off path is unchanged when `plan` is explicitly absent next to the new branch.

### Criterion 5 — no planning event payload or rendered result leaks the api_key
- Call chain: `soma_actor:send/2` → planning llm-call path with a sentinel `api_key` in `model_config` → run to completion → `soma_event_store:by_correlation/2` over the task's events
- Test entry: `soma_actor:send/2` then `by_correlation/2` (no layer bypassed; the scan is over the real emitted events)
- Test: `planning_mode_api_key_appears_in_no_emitted_event` in `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl`

## Risks & trade-offs

- Lisp-in-content depends on the model writing parseable s-expressions. A real model often will not on the first try. The malformed path is the safety net — it fails as data and (with repair on) gets one bounded retry — but a model that never produces clean Lisp will just fail the task. That is the accepted cost of choosing Lisp-in-content over native function-calling, which the issue puts out of scope.

- `build_call_opts/2` now needs the tool policy, so its signature or its input map changes. Every existing caller and the `soma_actor_call_opts_tests` cases that call it with two arguments have to move in step. This is a real ripple, not a drop-in.

- Marking the planning task and unwrapping its reply content reuses the directive-shaped seam in `proposal_result/2`. A planning task's reply is read as a plan, so a planning model that genuinely wants to answer in prose (not a plan) cannot — its prose would be parsed as Lisp and fail. In planning mode the model is told to emit a plan, so this is intended, but it means planning mode and plain-reply mode are a per-call choice, not a per-response one.

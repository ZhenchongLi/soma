---
title: Decision layer
description: The actor's decision step — proposals, the policy gate, and the LLM call seam.
---

The decision layer sits in front of execution: before the actor runs anything,
it asks for a proposal, normalizes it, and gates it through a policy. Proposals
are **data, not execution**.

## The call seam

`soma_llm_call` is a disposable, monitored, cancellable per-call worker the
actor owns directly. The single seam `soma_llm_call:perform_call/1` is where a
real provider slots in; the mock is directive-driven (`proposal` / `success` /
`slow` / `crash` / `hang`). A real OpenAI-compatible provider
(`soma_llm_openai`) fills this seam, while the mock stays the test-gate default
so the gate never reaches the network.

## Configured planning

The shipped OpenAI-compatible `[llm]` configuration enables planning with
`plan = true`:

```toml
[llm]
provider = "openai_compat"
base_url = "https://api.openai.com/v1"
model = "gpt-4.1-mini"
plan = true
```

Provider text is compiled as a Soma Lisp `(run-steps ...)` proposal. It then
passes proposal normalization, the tool-name policy gate, and the budget gate
before actor-owned supervised execution starts the approved steps as a
`soma_run`.

## Proposals

`soma_proposal:normalize/1` is a pure validate-and-normalize boundary. It tags
each proposal by `kind`: `reply`, `run_steps`, `reject`, `ask`, or
`actor_message`. A proposal is data — normalizing it never executes anything.

## The policy gate

`soma_policy:check/2` is pure. It gives a proposal an `allow` or
`{reject, Reason}` verdict against a tool-name allowlist, configured by
`#{allowed_tools => [atom()] | all}` — name-based only.

```erlang
%% A run_steps proposal is checked against the policy before any run starts.
case soma_policy:check(Proposal, #{allowed_tools => [echo, file_read]}) of
    allow            -> start_run(Proposal);
    {reject, Reason} -> reject_task(Reason)
end.
```

## Closing the loop

An approved `run_steps` proposal starts a `soma_run` the actor owns (emitting
`proposal.executed`); a toolless approved proposal completes with the proposal
as its result; an approved `actor_message` is delivered to another actor under
the sender's `correlation_id`. A `budget` (`#{max_llm_calls, max_steps}`) fails
the task on exhaustion (`{budget_exceeded, _}`) while the actor survives. The
new statuses are `approved` and `rejected`, with events
`proposal.created` / `proposal.approved` / `proposal.rejected` /
`proposal.executed` and `llm.started` / `llm.succeeded` / `llm.failed` /
`llm.timeout` / `llm.cancelled`.

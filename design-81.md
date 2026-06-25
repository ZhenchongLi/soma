# [cc] Clear unmatched erlang:cancel_timer return in soma_actor (dialyzer unmatched_returns from #77)

## Current state

`clear_llm_timer/2` in `apps/soma_actor/src/soma_actor.erl` cancels the call-timeout timer when an llm worker reports its terminal result. Line 518 calls `erlang:cancel_timer(TimerRef, [{async, false}, {info, false}])` and throws the return away on its own statement, then returns `Data`.

`rebar.config` turns on `unmatched_returns` for dialyzer. That option flags any expression whose value is dropped without being bound. `erlang:cancel_timer/2` has a return type of `'false' | 'ok' | non_neg_integer()`, and the bare call on line 518 leaves that value unmatched, so dialyzer reports a warning there.

The discard is intentional. With `{info, false}` the call returns `ok` and the timer is cancelled for its effect, not its value. The behavior is correct; the code just doesn't tell dialyzer the discard is deliberate.

`rebar3 dialyzer` is not in the merge gate (`rebar3 eunit && rebar3 ct`), so this warning landed on `main` through #77 without anything catching it. The repo now sits at 5 warnings: this one plus 4 pre-existing ones in `soma_lfe_reader.erl` (x3) and `soma_tool_call.erl` (x1).

## Approach

Bind the dropped return to `_`. That is the standard way to tell dialyzer a discard is on purpose under `unmatched_returns`.

```erlang
_ = erlang:cancel_timer(TimerRef, [{async, false}, {info, false}]),
Data
```

The timer is still cancelled. `clear_llm_timer/2` still returns `Data`. Nothing about the runtime path changes — the only difference is the `_ =` prefix, which dialyzer reads as an acknowledged discard.

Scope stays at the one line. The 4 other warnings in `soma_lfe_reader.erl` and `soma_tool_call.erl` are out of scope and those files are not touched.

## Acceptance criteria → tests

The primary fix is a dialyzer outcome, not a behavior the test suites assert. `rebar3 eunit && rebar3 ct` passes both before and after the change, so they can't prove the fix — they only guard against a regression in the timer's behavior. The criteria split into two groups below.

### Criterion 1 — line-518 unmatched_returns warning is gone
- Call chain: none (compile-time assertion). Dialyzer reads `apps/soma_actor/src/soma_actor.erl` and reports discrepancies against `rebar.config`'s `unmatched_returns`.
- Test entry: run `rebar3 dialyzer` and read its output; no warning naming `soma_actor.erl` line 518.
- Test: `rebar3 dialyzer` (manual; not a suite case)

### Criterion 2 — total warning count drops 5 to 4
- Call chain: none (compile-time assertion). Same dialyzer run, counted across the tree.
- Test entry: count the warnings `rebar3 dialyzer` prints; expect 4, all in `soma_lfe_reader.erl` (x3) and `soma_tool_call.erl` (x1).
- Test: `rebar3 dialyzer` (manual; not a suite case)

### Criterion 3 — clear_llm_timer/2 still returns Data and still cancels the timer
- Call chain: llm worker sends `{llm_result, ...}` to actor → `soma_actor` result handler → `clear_llm_call/2` → `clear_llm_timer/2` → `erlang:cancel_timer/2`. The successful path runs this when the worker finishes inside its bound.
- Test entry: `soma_actor:send/2` with a `success` envelope. The test starts at the public actor API and lets the real result path run through `clear_llm_timer/2`; no layer bypassed.
- Test: `get_task_result_holds_llm_output` in `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 4 — existing llm timeout and success cases still pass
- Call chain (timeout): the actor arms a call-timeout timer, the slow worker runs past it, the timer fires `{timeout, _, {llm_timeout, LlmCallId}}`, the actor kills the worker and records `timeout`. This exercises the arm/fire side of the same timer `clear_llm_timer/2` cancels.
- Test entry: `soma_actor:send/2` with a `slow` directive and a short `timeout_ms`. Real send path, real timer, no bypass.
- Test: `slow_call_times_out_worker_dead_actor_alive` in `apps/soma_actor/test/soma_llm_call_SUITE.erl`
- The success case is the same test as Criterion 3: `get_task_result_holds_llm_output` in `apps/soma_actor/test/soma_llm_call_SUITE.erl`

### Criterion 5 — rebar3 eunit && rebar3 ct stays green
- Call chain: none (whole-gate run). Runs every EUnit module and CT suite in the umbrella.
- Test entry: run `rebar3 eunit && rebar3 ct`; both exit 0.
- Test: `rebar3 eunit && rebar3 ct` (the merge gate; not a single case)

## Risks & trade-offs

The change is a one-character-class discard binding with no runtime effect, so there is little to weigh. The one honest gap: the fix is proven by `rebar3 dialyzer`, which is not in the merge gate. Nothing in `eunit`/`ct` will catch this warning coming back if a later change reintroduces it. The issue does not ask to add dialyzer to the gate, so that gap stays open after this fix.

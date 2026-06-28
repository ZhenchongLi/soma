# [cc] soma CLI: head timeout result with (result …); named error when ask has no model

## Current state

Two separate bugs in the local CLI daemon, both in `apps/soma_actor/src/soma_cli_server.erl`. The first also touches the `result`-head rule in `apps/soma_event_store/src/soma_lisp.erl`.

### Bug A — a timed-out run renders headless

`soma_lisp:render/1` only puts the leading `result` symbol on a map when `is_result_map/1` says so, and that guard is:

```
is_result_map(Map) ->
    maps:is_key(status, Map)
        andalso (maps:is_key(outputs, Map) orelse maps:is_key(error, Map)).
```

So a result map needs `status` plus one of `outputs` / `error`. The four terminal maps `await_run` builds:

- `run_completed` → `#{status => completed, ..., outputs => Outputs}` — has `outputs`, renders `(result …)`.
- `run_failed` → `#{status => failed, ..., error => Reason}` — has `error`, renders `(result …)`.
- `run_cancelled` → `#{status => cancelled, task_id, correlation_id}` — has neither.
- `run_timeout` → `#{status => timeout, task_id, correlation_id}` — has neither.

The cancelled and timeout maps fall through `is_result_map/1` to `render_value/1`, which renders them as a bare pair list `((status timeout) (task-id "…") (correlation-id "…"))` with no head. The issue names timeout, and its acceptance criterion pins timeout, so that is the case the test asserts. Cancelled has the same shape and the same defect.

A step whose work outlasts its `timeout_ms` is the real trigger: `soma_run`'s `waiting_tool` state timer fires `step_timeout`, the run records `run.timeout`, and `soma_run` sends `{run_timeout, RunId}` to the handler waiting in `await_run`.

### Bug B — ask with no model config returns a raw crash term

`handle_ask/2` builds the mock directive map with `mock_llm_opts(ModelConfig)`. With no `~/.soma/config`, `ModelConfig` is `undefined`, so `mock_llm_opts/1` hits its catch-all clause and returns `#{}`. That empty map travels as the envelope's `llm` map into the actor, down to `soma_llm_call:perform_call/1`. Every clause of `perform_call/1` matches on a key — `provider`, or a `directive` of `success` / `proposal` / `slow` / `hang` / `crash`. An empty map matches none, so the call throws `function_clause`. The actor records that as the task's failure reason, and `handle_ask/2`'s `{error, Reason}` branch renders it into the `error` sub-form. The client sees `(error "{function_clause,[{soma_llm_call,perform_call,[#{}],…}]}")` — an Erlang stack term leaking out of the wire.

## Approach

### Bug A — make timeout (and cancelled) a result map

`await_run`'s timeout map has no second-class status — it is a terminal run outcome like the others, it just carries no payload. The fix is to let `is_result_map/1` recognize a status-only result. The cleanest cut is a known-status whitelist: a map is a result map if it carries a `status` whose value is one of the terminal statuses the CLI emits (`completed`, `failed`, `timeout`, `cancelled`, `rejected`, `error`). That heads every terminal map the CLI builds, including the two payload-less ones, without changing the rendered form of the maps that already worked — `result_pairs/1` already emits `outputs` / `error` only when present, so a status-only map renders as `(result (status timeout) (task-id "…") (correlation-id "…"))`.

I am widening `is_result_map/1` rather than stuffing an empty `outputs => #{}` into `await_run`'s timeout map. An empty outputs sub-form would render `(outputs ())`, which reads as "the run produced no outputs" — but a timed-out run did not finish producing outputs at all, so that would be a misleading sub-form. The status-only map says exactly what is true: it terminated as `timeout`, with no outputs and no error.

The widened guard does not collide with the event-map and envelope-map branches below it: those are reached only when `is_result_map/1` is false, and an event map's `status` (if any) is not on the terminal-status whitelist. A bare `#{status => running}` registry map is not a terminal status either, so it still renders as a plain value, which is what `handle_status` already wants — it builds its `(status (state …))` reply by hand and never passes that map to `render/1`.

### Bug B — name the missing-model error

The fix is a guard in the ask path, not in `soma_llm_call`. `soma_llm_call:perform_call/1` is runtime-core and shared by the actor's mock and real paths; teaching it a `no_model_configured` clause would push a CLI-specific concern down into the runtime and break the one-way dependency rule. The CLI server is where the daemon's `model_config` is known to be absent, so it is where the guard belongs.

In `handle_ask/2`, before starting the actor, check whether `ModelConfig` is a usable mock/real config. Undefined or an empty map means no model is configured: short-circuit to a failed result whose `error` is the atom `no_model_configured`, and never start the actor or the call. A populated map (a mock directive map, or a real-provider map) flows on unchanged. The check is on `ModelConfig` directly — `undefined` or `#{}` (and any map with neither a `directive` nor a `provider` key) is "no model". The terminal map is `#{status => failed, task_id, correlation_id, error => no_model_configured}`, which already renders as a headed `(result …)` because it carries `error`.

`no_model_configured` is an atom, so `soma_lisp:render/1` renders it as the symbol `no-model-configured` inside `(error …)`. The criterion asks for "the named atom `no_model_configured`"; the test asserts on the rendered symbol form. The atom value is fixed per the issue's open-question note.

Returning the failure without starting the actor also satisfies the survival criterion for free: nothing is spawned, so there is nothing to crash, and the handler closes its socket the same way every other reply does. The listener process is untouched, so the next request on the same daemon is served normally.

## Acceptance criteria → tests

### Criterion 1 — a timed-out run replies a headed `(result …)` with `(status timeout)`
- Call chain: gen_tcp client sends `(run (step wait sleep (args (ms 3000)) (timeout_ms 500)))` over the local socket → `handle` → `handle_lisp_request` → `soma_lfe:compile` → `run_steps` → `soma_run_sup:start_run` → `soma_run` `waiting_tool` state timer fires `step_timeout` → records `run.timeout`, sends `{run_timeout, RunId}` → `await_run` builds the timeout map → `soma_lisp:render/1`
- Test entry: the gen_tcp client over the real Unix socket (no layer bypassed — same end-to-end shape as the other `soma_cli_server_SUITE` run cases)
- Test: `test_run_timeout_returns_result_with_status_timeout` in `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 1 (unit) — `render/1` heads a status-only timeout map
- Call chain: none (direct function call) — `soma_lisp:render/1` on a hand-built `#{status => timeout, task_id, correlation_id}` map
- Test entry: `soma_lisp:render/1` directly, the same way the existing render tests call it
- Test: `test_render_status_only_timeout_map_heads_result` in `apps/soma_event_store/test/soma_lisp_tests.erl`

### Criterion 2 — ask with no model config returns a `failed` result named `no_model_configured`
- Call chain: gen_tcp client sends `(ask (intent "…"))` to a server started with no `model_config` → `handle` → `handle_lisp_request` → `handle_ask/2` → no-model guard → terminal failed map → `soma_lisp:render/1`
- Test entry: the gen_tcp client over the real Unix socket, server started by `start_link(#{socket => Path})` with no `model_config` key (the `undefined` daemon default)
- Test: `test_ask_no_model_returns_named_no_model_configured` in `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 3 — the server survives the no-model failure and serves the next request
- Call chain: same no-model ask chain as Criterion 2 on connection one, then a fresh connection sends an echo `(run (step s1 echo (args (value "ok"))))` → `run_steps` → `soma_run` → `(result (status completed) …)`
- Test entry: two gen_tcp clients over the same daemon's socket (the same survive-and-serve pattern the malformed-request and failed-run cases use)
- Test: `test_server_serves_after_no_model_ask` in `apps/soma_actor/test/soma_cli_server_SUITE.erl`

## Risks & trade-offs

The widened `is_result_map/1` keys off a fixed list of terminal status atoms. If a new terminal status is added later and not put on the list, its status-only map would render headless again — the same trap, just moved. The alternative (treating any map with a `status` key as a result map) would be simpler but would wrongly head event maps and the registry's `#{status => running}` map if either ever reached `render/1`. I chose the whitelist because it keeps the three existing map-kind branches (result / event / envelope) cleanly separated; the cost is that the list has to be kept in step with the CLI's terminal statuses.

The Bug B guard treats "a map with neither `directive` nor `provider`" as no-model, not just `undefined` / `#{}`. That is slightly broader than the two shapes the issue names. The upside is it catches a half-filled config map that would otherwise reach `perform_call/1` and throw the same `function_clause`. The downside is that a future, validly-shaped mock config that happens to use neither key would be wrongly rejected as no-model — no such shape exists today, and adding one would mean revisiting this guard anyway.

## Current state

Soma already has the boundaries this issue needs:

- `soma_run` resolves tools through `soma_tool_registry:resolve_descriptor/1` and starts every invocation in a `soma_tool_call` worker. The worker late-binds `erlang_module` descriptors through `Module:invoke/2`, so a tool module can live in `soma_actor` without `soma_runtime` importing the actor layer.
- `soma_tool_registry:register_tool/1` normalizes manifests and stores descriptors. `catalog/0` exposes only described tools as `#{name, description, params}` entries.
- `soma_actor_registry` maps binary stable names to live actor pids and returns `{error, not_found}` for unknown or dead names.
- `soma_actor:ask/3` blocks the caller through a parked gen_statem call and completes from the normal task lifecycle. `send/2` already accepts stable names, and actor-to-actor proposal delivery already proves correlation id propagation when an envelope carries `correlation_id`.
- `soma_actor` owns task cancellation through `cancel/2`: it sends `cancel` to the active owned run, records `actor.task.cancelled`, releases waiters, and stays alive.
- `soma_run` already carries `correlation_id` in its state and stamps it on run events, but `start_tool_call/7` currently builds the tool `ctx` with only `session_id`, `run_id`, `step_id`, and `tool_call_id`. A tool cannot currently read the parent run correlation id from `ctx`.
- `soma_actor.app:start/2` currently only starts `soma_actor_sup`; it does not register any actor-owned tools at application boot.
- A parked `ask/3` waiter is stored in `Data#data.waiters`, but the actor does not monitor the asking process. If the asking process dies after the ask is parked, the target task currently keeps running unless some other owner cancels it.

No `soma_tool_ask_actor` module exists yet.

## Approach

Add `soma_tool_ask_actor` in `apps/soma_actor/src/` as a normal `erlang_module` tool. It should export `manifest/0`, `describe/0` if the local tool convention still expects it, and `invoke/2`.

The manifest should be conservative and model-facing:

- `name => ask_actor`
- `effect => state`
- `idempotent => false`
- `timeout_ms` set to a generous default such as `60000`
- `adapter => erlang_module`
- `module => soma_tool_ask_actor`
- non-empty binary `description`
- params documenting a binary `target` stable name and a map `envelope`

Register this manifest when the `soma_actor` app boots, after `soma_runtime` has started its registry. The least invasive place is `soma_actor_app:start/2`: start `soma_actor_sup`, call `soma_tool_registry:register_tool(soma_tool_ask_actor:manifest())`, and return the supervisor pid. If registration fails, fail app boot rather than silently booting a partially capable actor layer. Keep `soma_runtime.app.src` free of `soma_actor`, preserving the one-way dependency.

Define the tool input as a map:

```erlang
#{target := StableName, envelope := Envelope}
```

`StableName` must be a binary and `Envelope` must be a map accepted by `soma_actor:ask/3`. Do not create atoms from input. On invalid input, return bounded named errors such as `{invalid_ask_actor_input, missing_target}`, `{invalid_ask_actor_input, invalid_target}`, or `{invalid_ask_actor_input, invalid_envelope}`.

`invoke/2` should:

1. Resolve `StableName` with `soma_actor_registry:lookup/1`.
2. If lookup fails, return `{error, {ask_actor_lookup_failed, not_found}}` or an equivalent bounded named error that carries `not_found`.
3. Build the child envelope from `Envelope`, adding the parent `correlation_id` from `Ctx` when present. If the envelope already carries a different `correlation_id`, overwrite it with the parent id, matching the existing actor-to-actor delivery rule that the sender's correlation id wins.
4. Call `soma_actor:ask(TargetPid, ChildEnvelope, AskTimeoutMs)`.
5. Return the target task result as the step output: `{ok, Result}` for `{ok, Result}`, `{error, Reason}` for `{error, Reason}`, and `{error, timeout}` if `ask/3` itself times out.

Thread the parent correlation id into tool context by adding `correlation_id => Data#data.correlation_id` in `soma_run:start_tool_call/7` only when it is not `undefined`. This is metadata only: no step schema, adapter vocabulary, worker protocol, or run state machine behavior changes.

Implement ask-death cancellation in `soma_actor`, not in runtime:

- When `idle({call, From}, {ask, Envelope}, Data)` parks a waiter for a task that started a run or LLM call, extract the caller pid from the gen_statem `From` tuple and monitor that process.
- Track waiter monitor refs separately enough to distinguish them from run and LLM worker monitors. A small map such as `waiter_monitors = #{MRef => TaskId}` plus `waiter_mrefs = #{TaskId => MRef}` keeps teardown explicit.
- On `{'DOWN', MRef, process, _Pid, _Reason}` for a waiter monitor, if the task is still running, cancel it through the same owner path as `cancel/2`: send `cancel` to a live run pid, or kill/cancel a live LLM worker if the task is in the LLM path. Marking the task should still happen through the existing terminal messages where possible, so `actor.task.cancelled` and waiter cleanup stay consistent.
- On normal task completion, failure, timeout, cancellation, or immediate no-child ask reply, demonitor the waiter with `[flush]` and remove both waiter-monitor indexes. This ensures the asker's later death cannot change a completed task.
- If `ask/3` times out on the caller side, that caller death is not guaranteed; the new mechanism is specifically for process death, which covers parent run timeout and run cancellation because both kill the `soma_tool_call` worker that is blocked in `soma_actor:ask/3`.

Keep the runtime ignorant of actors. `soma_tool_call` still just invokes an `erlang_module`; `soma_run` still just kills the active worker on timeout/cancel; the child's cancellation follows because the target actor monitors the worker process that called `ask/3`.

Update the relevant contract documentation after implementation, preferably a new `docs/contracts/tool-ask-actor-test-contract.md` plus a pointer from `docs/tool-abstraction.md` T.4. The design file itself is the only file changed in this stage.

## Acceptance criteria -> tests

| Acceptance criterion | Test mapping |
| --- | --- |
| After `soma_actor` app boot, `resolve_descriptor(ask_actor)` returns the descriptor and `catalog/0` lists it with description. | Add EUnit in `apps/soma_actor/test/soma_actor_app_tests.erl`: `ask_actor_registered_after_app_boot_test` starts `soma_actor`, asserts `{ok, #{name := ask_actor, adapter := erlang_module, module := soma_tool_ask_actor, effect := state, idempotent := false}} = soma_tool_registry:resolve_descriptor(ask_actor)`, and asserts catalog contains `#{name := ask_actor, description := Desc}` with non-empty binary `Desc`. |
| A run step naming `ask_actor` with target stable name and message payload returns the target actor task result end-to-end through session -> run -> tool-call, with its own worker process. | Add CT suite `apps/soma_actor/test/soma_tool_ask_actor_SUITE.erl`: `ask_actor_run_step_returns_target_result` boots `soma_actor`, starts a named target actor, starts a session run with `#{id => s1, tool => ask_actor, args => #{target => <<"child">>, envelope => #{type => <<"actor.message">>, payload => #{}, steps => [#{id => child_s1, tool => echo, args => #{value => <<"ok">>}}]}}}`, waits for `run.completed`, and asserts the parent `step.succeeded` output is the child ask result. `ask_actor_invocation_uses_tool_worker` reads parent `tool.started.tool_call_pid` and asserts it is a live/distinct worker pid, not the run pid. |
| Parent run `correlation_id` propagates to the sub-agent task and `by_correlation/2` returns sub-agent task events. | In `soma_tool_ask_actor_SUITE`, `ask_actor_propagates_parent_correlation_id` starts the parent run directly under `soma_run_sup` or an actor-owned run with a known `correlation_id`, invokes `ask_actor`, then asserts `soma_event_store:by_correlation(Store, Corr)` contains parent `run.*`/`tool.*` events and child `actor.message.received` / `actor.task.accepted` / terminal child events for the target actor id. |
| Step timeout and parent run cancel both propagate to the sub-agent through asker-death monitoring; target actor survives, child task is cancelled, parent session survives and runs again. | In `soma_tool_ask_actor_SUITE`, add `ask_actor_step_timeout_cancels_child_task` using a child envelope with a known `task_id` and long `sleep` step while the parent `ask_actor` step has short `timeout_ms`; assert parent `run.timeout`, parent tool worker dead, target `get_task_status(Target, ChildTaskId)` eventually `cancelled`, target pid alive, and the same session completes a later `echo` run. Add sibling `ask_actor_parent_cancel_cancels_child_task` starting the same long ask without short timeout, waiting for parent `tool.started`, sending `{cancel_run, ParentRunId}` to the session, then asserting parent `run.cancelled`, child task cancelled, target alive, and session can run again. |
| Unknown or dead stable name fails the run with bounded named error data carrying registry `not_found`, and the session survives. | In `soma_tool_ask_actor_SUITE`, add `ask_actor_unknown_name_fails_run_session_alive` and `ask_actor_dead_name_fails_run_session_alive`. Start parent session runs naming `ask_actor` with `target => <<"ghost">>` or a stable name whose actor was killed. Assert parent `run.failed` payload reason matches the named ask_actor lookup error and contains `not_found`; assert session pid alive and a later `echo` run completes. |
| Once an ask has been answered, the asker's later death changes nothing: completed task status stays completed and target actor stays alive. | In `soma_tool_ask_actor_SUITE`, `asker_death_after_answer_does_not_cancel_completed_child` starts a short child task with a known child `task_id`, waits for parent run completion and child status `completed`, then kills/exits the parent tool worker if still possible or uses a direct helper process calling `soma_actor:ask/3` to prove the waiter monitor is removed after reply. Assert child status remains `completed`, no `actor.task.cancelled` for that task appears, and target pid remains alive. |

Also add or update static/app-boundary tests:

- Extend `soma_actor_app_tests` or a new source scan to assert no file under `apps/soma_runtime/src` references `soma_actor` or `soma_tool_ask_actor`.
- Add the new contract document to an existing doc-read EUnit test or a new one under `apps/soma_tools/test/`, matching the repository's "tests are the contract" pattern.

## Risks & trade-offs

- Boot-time tool registration depends on the runtime registry already running. `soma_actor.app.src` already depends on `soma_runtime`, so app start ordering should support this; tests should use `application:ensure_all_started(soma_actor)` rather than manually starting only `soma_actor_sup` when proving registration.
- The tool input shape must be explicit. `#{target, envelope}` is simple and avoids inventing actor lifecycle or name-spawning behavior, but docs and tests need to lock it down so future Lisp/planner layers can compile to it consistently.
- The child ask timeout value inside `soma_tool_ask_actor` should be longer than normal step bounds, because the parent step timeout is the authoritative bound. Too short a tool-internal ask timeout would fail a valid parent step early; too long is acceptable because parent timeout/cancel kills the worker.
- Monitoring parked ask callers requires careful bookkeeping distinct from existing run and LLM monitors. Reusing the current `monitors` map without tagging monitor kinds risks treating caller death like worker death or vice versa.
- Process-death cancellation only fires when the asker process dies. That exactly covers parent step timeout/cancel because `soma_run` kills the tool worker, but it does not mean every client-side `ask/3` timeout cancels work. This should remain explicit in docs and tests.
- Overwriting an existing child-envelope `correlation_id` with the parent id is consistent with existing actor-to-actor delivery, but it is a policy choice. Keeping it strict avoids split traces for recursive chains.
- The unknown/dead actor error should be bounded and named without exposing process-local refs or pids. Carrying `not_found` is enough for callers and tests.

# [cc] actor registry: resolve stable names to live pids

## Current state

Actors are started under `soma_actor_sup:start_actor/1` and are addressed by pid.
The public `soma_actor:send/2` path sends its first argument straight to
`gen_statem:call/2`.

`actor_id` is an event label. It is not a live address. Nothing in the actor
layer can map that label, or any other stable name, back to the current actor
pid.

Approved `actor_message` proposals already deliver through the normal
`soma_actor:send/2` entry point. That path is a good fit for name resolution, but
`soma_proposal:normalize/1` currently accepts only pid targets for
`actor_message`. A binary target such as `<<"actor-a2">>` is treated as a
malformed proposal before the approved delivery path can run.

## Approach

Add a local actor-layer registry named `soma_actor_registry`. It belongs in
`apps/soma_actor`, not in `soma_runtime`. Runtime code must not learn about actor
names.

Use a new actor start option, `stable_name`, for registration. The name is a
binary. It is separate from `actor_id`, which continues to be the event label.
Actors without `stable_name` keep pid-only behavior.

Start the registry under the actor application supervision tree. Since
`soma_actor_sup` is currently a `simple_one_for_one` supervisor, change its shape
to keep the public `soma_actor_sup:start_actor/1` API while adding a supervised
registry child. One simple shape is:

```text
soma_actor_sup
  |-- soma_actor_registry
  `-- soma_actor_child_sup
        `-- soma_actor
```

`soma_actor_sup:start_actor/1` should delegate to the child supervisor. Existing
callers should not need to change.

`soma_actor_registry` stores `StableName => Pid` and monitors each registered
pid. `lookup/1` returns `{ok, Pid}` only when the name is present and the pid is
alive. It returns `{error, not_found}` for unknown names and for stale entries.
When a named actor exits, the monitor removes that name if it still points at the
dead pid. When a later actor registers the same `stable_name`, the new pid
replaces the old entry. A stale monitor message from the old pid must not remove
the new entry.

Register from `soma_actor:init/1` when `stable_name` is present. That keeps the
registration tied to the actor process that owns the name. After
`soma_actor_sup:start_actor/1` returns, a production lookup should already be able
to find the pid.

Add a small resolver in `soma_actor`. Pids keep the existing path. Binary actor
refs are looked up in `soma_actor_registry`. Unknown names return
`{error, not_found}` without calling `gen_statem:call/2`.

For `send/2` with a Lisp source body, keep the current parse-first behavior. The
wrapper compiles the source into an envelope, then calls the map-envelope `send/2`
clause. That preserves current parse errors and adds name lookup at the same
point as the map path.

Widen `soma_proposal:normalize/1` so an `actor_message` target may be a pid or a
binary stable name. Payload validation stays the same. Pid targets remain valid.
Binary stable names do not bypass policy. They only allow the existing approved
`actor_message` path to call `soma_actor:send/2`, where the target is resolved.

When an approved `actor_message` names an unknown actor, `soma_actor:send/2`
returns `{error, not_found}`. The existing delivery error branch should mark the
sender task failed with `{delivery_failed, not_found}`. The sender actor remains
alive.

## Acceptance criteria → tests

### Criterion 1 — lookup finds a named actor
- Call chain: `soma_actor_sup:start_actor/1` → `soma_actor:init/1` → `soma_actor_registry:register/2` → `soma_actor_registry:lookup/1`
- Test entry: `soma_actor_sup:start_actor/1`
- Test: `lookup_registered_actor_returns_pid` in `apps/soma_actor/test/soma_actor_registry_SUITE.erl`

### Criterion 2 — send accepts a registered name
- Call chain: `soma_actor:send/2` → actor-ref resolver → `soma_actor_registry:lookup/1` → `gen_statem:call/2` → `soma_actor:idle/3`
- Test entry: `soma_actor:send/2`
- Test: `send_registered_name_returns_task_id` in `apps/soma_actor/test/soma_actor_registry_SUITE.erl`

### Criterion 3 — send by name creates a task on the looked-up actor
- Call chain: `soma_actor:send/2` → actor-ref resolver → `soma_actor_registry:lookup/1` → `gen_statem:call/2` → `soma_actor:idle/3` → actor task table
- Test entry: `soma_actor:send/2`
- Test: `send_registered_name_creates_task_on_actor` in `apps/soma_actor/test/soma_actor_registry_SUITE.erl`

### Criterion 4 — proposal normalize accepts a stable-name target
- Call chain: none (direct normalize boundary)
- Test entry: `soma_proposal:normalize/1`
- Test: `actor_message_stable_name_normalizes_ok_test` in `apps/soma_actor/test/soma_proposal_tests.erl`

### Criterion 5 — actor_message by name delivers after approval
- Call chain: `soma_actor:send/2` on A1 → `soma_actor:idle/3` → `soma_llm_call` mock result → `soma_proposal:normalize/1` → `soma_policy:check/2` → `execute_actor_message/5` → `soma_actor:send/2` on stable name → `soma_actor_registry:lookup/1` → A2 `soma_actor:idle/3`
- Test entry: `soma_actor:send/2` on A1
- Test: `actor_message_stable_name_delivers_task_after_approval` in `apps/soma_actor/test/soma_actor_message_SUITE.erl`

### Criterion 6 — restart replaces the registered pid
- Call chain: first `soma_actor_sup:start_actor/1` → `soma_actor_registry:register/2` → actor exit monitor → second `soma_actor_sup:start_actor/1` → `soma_actor_registry:register/2` → `soma_actor_registry:lookup/1`
- Test entry: `soma_actor_sup:start_actor/1`
- Test: `restart_named_actor_replaces_registry_pid` in `apps/soma_actor/test/soma_actor_registry_SUITE.erl`

### Criterion 7 — unknown lookup returns not_found
- Call chain: `soma_actor_registry:lookup/1`
- Test entry: `soma_actor_registry:lookup/1`
- Test: `lookup_unknown_stable_name_returns_not_found` in `apps/soma_actor/test/soma_actor_registry_SUITE.erl`

### Criterion 8 — send to an unknown name returns not_found
- Call chain: `soma_actor:send/2` → actor-ref resolver → `soma_actor_registry:lookup/1`
- Test entry: `soma_actor:send/2`
- Test: `send_unknown_stable_name_returns_not_found` in `apps/soma_actor/test/soma_actor_registry_SUITE.erl`

### Criterion 9 — unknown-name send keeps the caller alive
- Call chain: spawned caller → `soma_actor:send/2` → actor-ref resolver → `soma_actor_registry:lookup/1`
- Test entry: spawned caller process
- Test: `send_unknown_stable_name_keeps_caller_alive` in `apps/soma_actor/test/soma_actor_registry_SUITE.erl`

### Criterion 10 — unknown-name actor_message fails the sender task
- Call chain: `soma_actor:send/2` on A1 → `soma_actor:idle/3` → `soma_llm_call` mock result → `soma_proposal:normalize/1` → `soma_policy:check/2` → `execute_actor_message/5` → `soma_actor:send/2` on unknown stable name → `soma_actor_registry:lookup/1` → `fail_task/3`
- Test entry: `soma_actor:send/2` on A1
- Test: `actor_message_unknown_stable_name_fails_sender_task` in `apps/soma_actor/test/soma_actor_message_SUITE.erl`

### Criterion 11 — unknown-name actor_message keeps the sender alive
- Call chain: `soma_actor:send/2` on A1 → `soma_actor:idle/3` → `soma_llm_call` mock result → `soma_proposal:normalize/1` → `soma_policy:check/2` → `execute_actor_message/5` → `soma_actor:send/2` on unknown stable name → `soma_actor_registry:lookup/1` → `fail_task/3`
- Test entry: `soma_actor:send/2` on A1
- Test: `actor_message_unknown_stable_name_keeps_sender_alive` in `apps/soma_actor/test/soma_actor_message_SUITE.erl`

## Risks & trade-offs

Changing `soma_actor_sup` from a dynamic-only supervisor to a root supervisor with
a child supervisor is a real structural edit. It keeps the public
`soma_actor_sup:start_actor/1` API, but any test that inspects supervisor
children may need to expect the registry and child supervisor.

Stable names are binary-only in this slice. That avoids atom table growth, but
callers that wanted atom names must convert them.

If two live actors register the same `stable_name`, the later registration wins.
The issue only asks for replacement after the old process exits, so tests should
cover that path. The last-writer rule keeps the registry small and local.

A race remains possible if a pid dies after lookup and before `gen_statem:call/2`.
This is the same kind of race callers already have when they hold a pid. The new
guarantee is that unknown names and cleaned-up stale names return
`{error, not_found}` without killing the caller.

# Ask Actor Tool Test Contract

This contract covers `ask_actor`, the actor-owned `erlang_module` tool for
asking a named Soma actor from an ordinary run step (T.4 in
`docs/tool-abstraction.md`; issue #213). The runtime still knows only the
registry descriptor and `soma_tool_call`; actor lookup, `ask/3`, and child-task
teardown stay inside `soma_actor`.

## Boot And Registry

| Behavior | Proof |
| --- | --- |
| Starting `soma_actor` registers `ask_actor` as a stateful, non-idempotent `erlang_module` tool and exposes it in `catalog/0` with a non-empty description. | `soma_actor_app_tests:ask_actor_registered_after_app_boot_test` |
| `soma_runtime` keeps the one-way dependency: no runtime app or module names `soma_actor` or `soma_tool_ask_actor`. | `soma_actor_app_tests:test_runtime_app_src_excludes_soma_actor_test`, `soma_actor_app_tests:test_no_runtime_module_references_soma_actor_test` |

## Run-Step Behavior

| Behavior | Proof |
| --- | --- |
| A parent session run can invoke `ask_actor` by stable actor name; the call crosses a `soma_tool_call` worker process and returns the child actor's step outputs as the parent step output. | `soma_tool_ask_actor_SUITE:ask_actor_run_step_returns_target_result_and_uses_tool_worker` |
| The parent run's `correlation_id` is stamped onto the child actor task, so `by_correlation/2` returns both the parent run/tool events and child actor task events. | `soma_tool_ask_actor_SUITE:ask_actor_propagates_parent_correlation_id` |
| Naming an unknown or dead stable actor name fails the parent run with bounded `ask_actor_lookup_failed` data carrying the registry's `not_found`, while the session stays alive for a later run. | `soma_tool_ask_actor_SUITE:ask_actor_unknown_name_fails_run_session_alive`, `soma_tool_ask_actor_SUITE:ask_actor_dead_name_fails_run_session_alive` |

## Teardown Behavior

| Behavior | Proof |
| --- | --- |
| A parent `ask_actor` step timeout kills the asker's tool worker; the target actor observes that asker death, cancels the child task, stays alive, and the parent session completes a later run. | `soma_tool_ask_actor_SUITE:ask_actor_step_timeout_cancels_child_task` |
| Cancelling the parent run while `ask_actor` is parked kills the asker's tool worker; the target actor observes that asker death, cancels the child task, stays alive, and the parent session completes a later run. | `soma_tool_ask_actor_SUITE:ask_actor_parent_cancel_cancels_child_task` |

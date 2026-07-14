# AS.3 Test Contract — bounded reader-only exploration loop

This document maps every behavioural guarantee of the AS.3 exploration slice
(issue #231) to the test that proves it. Explore mode is an optional bounded
multi-round loop owned by `soma_actor`: each round the model either requests a
reader-only `(explore ...)` mini-run and receives a bounded observation, or
emits a terminal proposal that re-enters the existing
normalize → policy → budget → execute path. `soma_run` is unchanged; every
tool execution still crosses `soma_run -> soma_tool_call`.

## Criterion 1 — explore-mode round-reply dispatch

| Guarantee | Proof |
| --- | --- |
| `model_config` with `explore => true` treats provider text as an exploration-round reply. | `soma_actor_explore_SUITE:explore_mode_provider_text_is_parsed_as_round_reply` |

## Criterion 2 — explore round prompt

| Guarantee | Proof |
| --- | --- |
| Explore-mode system messages render the same policy-filtered catalog blocks as planning mode. | `soma_actor_call_opts_tests:test_explore_prompt_reuses_policy_filtered_catalog_blocks` |
| Explore-mode system messages state the reader-only/terminal round protocol and report the current round plus remaining `max_explore_rounds` allowance. | `soma_actor_call_opts_tests:test_explore_prompt_states_protocol_round_and_remaining_allowance` |

## Criterion 3 — owned execution across process boundaries

| Guarantee | Proof |
| --- | --- |
| A reader `(explore ...)` reply starts an owned `soma_run` under `soma_run_sup`, and each explore step executes in a `soma_tool_call` worker distinct from the run and actor pids. | `soma_actor_explore_SUITE:reader_explore_run_and_tool_worker_are_distinct_children` |

## Criterion 4 — end-to-end loop spine

| Guarantee | Proof |
| --- | --- |
| A fixed-response `(explore ...)` reply followed by a terminal `(run-steps ...)` completes through `soma_actor:send/2`; the explore run's outputs appear as a structured observation in the second LLM request and the final run's step outputs land in the task result. | `soma_actor_explore_SUITE:reader_then_terminal_run_steps_carries_observation_and_outputs` |

## Criterion 5 — reader-only gate

| Guarantee | Proof |
| --- | --- |
| A non-reader `(explore ...)` reply becomes a bounded rejection observation naming the offending tool and descriptor effect, with no `run.started` event, and the loop continues. | `soma_actor_explore_SUITE:non_reader_explore_rejected_with_effect_and_no_run` |

## Criterion 6 — bounded observations

| Guarantee | Proof |
| --- | --- |
| An observation over configured `max_observation_bytes => N` retains at most N serialized step-output bytes plus a fixed `(truncated true)` marker outside the count. | `soma_actor_explore_SUITE:configured_observation_cap_counts_only_retained_output_bytes` |
| An omitted `max_observation_bytes` bounds retained data to 16384 bytes. | `soma_actor_explore_SUITE:default_observation_cap_is_16384_bytes` |

## Criterion 7 — nonterminal failures become observations

| Guarantee | Proof |
| --- | --- |
| A failed explore run becomes the next round's bounded status observation at one fewer remaining round. | `soma_actor_explore_SUITE:failed_explore_run_becomes_next_round_observation` |
| A timed-out explore run becomes the next round's bounded status observation at one fewer remaining round. | `soma_actor_explore_SUITE:timed_out_explore_run_becomes_next_round_observation` |
| A round reply that parses to neither `(explore ...)` nor a proposal becomes the next round's bounded diagnostic observation at one fewer remaining round. | `soma_actor_explore_SUITE:invalid_round_reply_becomes_bounded_next_observation` |

## Criterion 8 — round budgets

| Guarantee | Proof |
| --- | --- |
| `max_explore_rounds => N` fails the task with `{budget_exceeded, max_explore_rounds}` after N nonterminal replies, before any (N+1)th `llm.started` event. | `soma_actor_explore_SUITE:configured_round_limit_stops_before_next_llm_start` |
| An omitted `max_explore_rounds` defaults to five rounds with the same exhaustion result. | `soma_actor_explore_SUITE:default_round_limit_is_five` |
| Every exploration round consumes exactly one unit from the existing `max_llm_calls` budget. | `soma_actor_explore_SUITE:explore_rounds_consume_existing_llm_call_budget` |

## Criterion 9 — in-loop LLM failures are terminal task data

| Guarantee | Proof |
| --- | --- |
| An LLM worker crash after at least one explore observation becomes terminal `failed` task data. | `soma_actor_explore_SUITE:in_loop_llm_crash_is_terminal_failed` |
| An owner-enforced LLM timeout after at least one explore observation becomes terminal `timeout` task data. | `soma_actor_explore_SUITE:in_loop_llm_timeout_is_terminal_timeout` |

## Criterion 10 — cancellation teardown

| Guarantee | Proof |
| --- | --- |
| Cancelling during an LLM round terminates the active `soma_llm_call` worker and records terminal `cancelled` task data. | `soma_actor_explore_SUITE:cancel_during_llm_round_kills_worker_and_cancels_task` |
| Cancelling during an explore run terminates the owned `soma_run` process tree and records terminal `cancelled` task data. | `soma_actor_explore_SUITE:cancel_during_explore_run_kills_tool_worker_and_cancels_task` |

## Criterion 11 — actor survival

| Guarantee | Proof |
| --- | --- |
| After round exhaustion the same actor completes a later task. | `soma_actor_explore_SUITE:actor_reusable_after_round_exhaustion` |
| After an in-loop LLM failure the same actor completes a later task. | `soma_actor_explore_SUITE:actor_reusable_after_in_loop_llm_failure` |
| After exploration cancellation the same actor completes a later task. | `soma_actor_explore_SUITE:actor_reusable_after_exploration_cancel` |

## Criterion 12 — terminal replies re-enter the existing proposal path

| Guarantee | Proof |
| --- | --- |
| A terminal `(run-steps ...)` produces the planning-mode `proposal.created` → `proposal.approved` → `proposal.executed` suffix. | `soma_actor_explore_SUITE:terminal_run_steps_reuses_proposal_execution_suffix` |
| A terminal `(reply ...)` completes with normalized proposal data and no `run.started` event. | `soma_actor_explore_SUITE:terminal_reply_completes_without_run` |
| A policy-rejected terminal `(run-steps ...)` ends as `rejected` task data with no `run.started` event. | `soma_actor_explore_SUITE:terminal_policy_rejection_starts_no_run` |
| A terminal `(run-steps ...)` over `max_steps` fails with `{budget_exceeded, max_steps}` before any `run.started` event. | `soma_actor_explore_SUITE:terminal_max_steps_failure_starts_no_run` |

## Criterion 13 — bounded round events and trace order

| Guarantee | Proof |
| --- | --- |
| Every round emits `explore.round.started` before `explore.round.completed` on the task correlation trail, exploration events add only the allowlisted keys (`actor_id`, `task_id`, `correlation_id`, `round`, `remaining_rounds`, `action`, `status`, `observation_bytes`, `truncated`), `action` is one of `explore \| proposal \| invalid_reply`, and `status` is one of `completed \| rejected \| failed \| timeout \| cancelled`. | `soma_actor_explore_SUITE:round_events_use_bounded_schema_and_order` |
| A rendered trace line shows an exploration event's round number. | `soma_trace_tests:test_timeline_renders_explore_round_number` |
| `soma_trace:render/2` prints every exploration round number in ascending order before the terminal proposal/run suffix. | `soma_trace_tests:test_render_prints_explore_rounds_in_order_before_terminal_suffix` |

## Criterion 14 — this contract

| Guarantee | Proof |
| --- | --- |
| This document names the proving test for every acceptance criterion of #231. | `soma_as3_contract_doc_tests:test_as3_contract_names_every_acceptance_proof` |

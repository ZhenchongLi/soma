### Claude

## Verdict
approve

## Real issues

None.

## Questions

- `planning_tools/2` overwrites `model_config`'s `allowed_tools` from the actor's `tool_policy` on every llm call. The real path feeds the names from the policy; the criterion-2 unit test calls `build_call_opts/2` directly and sets `allowed_tools` on the model_config. Two entry points, one source of truth each. They happen to agree today. If a caller ever sets `allowed_tools` on a real-provider `model_config` and expects it honored, the policy will silently win. Intended?

## Nits

- `planning_tools/2`, `planning_output/2`, `planning_directive/1`, `planning_system_prompt/1` are four small helpers each gated on `plan => true`. Reads fine. No change asked.

## Functional evidence
- Criterion 1 — pass: `planning_mode_real_response_runs_plan_to_completion` (soma_actor_real_provider_SUITE) drives `send/2` with a fixed `{200, Body}` whose content is `(run-steps (step (id s1) (tool echo) (args (value "a"))))`; asserts `proposal.executed` and `run.completed` in the `by_correlation` trail and `get_task_result` returns `#{s1 := #{value := <<"a">>}}`. CT green.
- Criterion 2 — pass: `test_planning_mode_builds_run_steps_system_message_over_allowed_tools` (soma_actor_call_opts_tests) asserts the first built message is `role => <<"system">>` whose content contains `(run-steps`, `echo`, and `file_read`, with the user message following unchanged. EUnit `7 tests, 0 failures`.
- Criterion 3 — pass: `planning_mode_malformed_plan_fails_task_actor_alive` feeds an unterminated s-expr; task reaches terminal `failed` with a non-undefined reason (compile diagnostics), `is_process_alive(ActorPid)` true, and a follow-up `steps` send reaches `completed`. `maybe_repair/5` falls through to terminal `failed` because a fresh planning call carries no staged `repair_output`. CT green.
- Criterion 4 — pass: `planning_mode_off_yields_reply_proposal_unchanged` uses a real-provider config with no `plan` key and plan-shaped content; `get_task_result` returns `#{kind := reply, text := Content}` verbatim, and the trail carries no `proposal.executed` / `run.completed`. CT green.
- Criterion 5 — pass: `planning_mode_api_key_appears_in_no_emitted_event` runs a planning plan to completion with a sentinel `api_key`; `lists:any(term_contains/2)` over the `by_correlation` events is false, and `soma_lisp:render` of the result has `binary:match = nomatch` for the sentinel. `llm.started` payload is built field-by-field (task_id, correlation_id, llm_call_id, llm_call_pid) and never carries the key. CT green.

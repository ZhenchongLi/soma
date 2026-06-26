### Claude

## Verdict
approve

## Real issues

None.

## Questions

- Criteria 4 and 5 read "leaves the **receiver's** task in failed status." The code fails the **sender's** `actor_message` task. A malformed body fails `soma_lfe:compile/2` at the sender's `send/2` string clause, so no receiver task is ever created. design-107.md:198-204 documents this swap and the test asserts the sender task fails plus both pids survive. Intent holds — failed as data, no crash, actor lives. Flagging so the swap is a conscious sign-off.
- Criterion 6 says the map body reaches "the same terminal status it reached before L.2." Before L.2 a map-bodied `actor_message` carried a plain payload (`#{text => ...}`), the delivery wrapped it in an `actor.message` envelope with no `steps`, and the receiver stopped at `accepted` — it never ran. `map_body_path_unchanged` uses a new body shape (`#{type, payload, steps}`) and asserts `completed`. That's a new capability, not a status any map body reached pre-L.2. The genuine "v0.5.6 path untouched" claim is proven elsewhere: `soma_actor_message_SUITE` (plain-payload bodies, still `accepted`) stays green, and `build_delivery/2`'s else-branch still wraps a plain payload in the `actor.message` envelope. So the regression bar holds; the criterion's wording is the loose part.
- design-107.md:196 promised to "pin the precedence with a test" for the appended `(correlation-id ...)` winning over one a body already carried. No test delivers a Lisp body that already carries its own `(correlation-id ...)`. Last-wins fold order is asserted nowhere. If `parse_msg_fields` ever flips fold direction, the sender's id stops overriding and `by_correlation/2` splits the chain silently. No criterion requires it, so not a blocker — the documented safety net is just absent.

## Nits

- `soma_l2_mock_only_tests` greps the suite source for the substrings `http`/`https`/`api_key` etc. It guards the file's text, not the runtime. A stray `http` in a future comment false-trips it. By-construction is the right call for this slice; the literal-substring guard is brittle.

## Functional evidence
- Criterion 1 — pass: `lisp_body_reaches_same_terminal_status_as_map` in soma_actor_lisp_to_lisp_SUITE asserts `completed = LispStatus` then `LispStatus = MapStatus`, each receiver task read off its `actor.task.accepted` event under A1's correlation_id. Suite 6/6 green.
- Criterion 2 — pass: `lisp_body_produces_same_step_outputs_as_map` asserts `LispOutputs = MapOutputs` from each receiver's `get_task_result/2` (the run_completed outputs map). Suite green.
- Criterion 3 — pass: `by_correlation_spans_both_actors_for_lisp_body` reads `soma_event_store:by_correlation(Store, <<"corr-l2-span">>)` and asserts both `actor-a1-corr` and `actor-a2-corr` appear in the event actor_ids; sender appends `(correlation-id ...)` to the Lisp source so the receiver task lands under A1's id.
- Criterion 4 — pass: `malformed_lisp_body_marks_task_failed` delivers `<<"(msg (type chat) (payload \"hi\"">>` (no closing paren), asserts `failed = wait_for_terminal(A1, <<"task-l2-bad">>, 100)` and both pids alive. Failed task is the sender's (see Questions).
- Criterion 5 — pass: `actor_alive_and_accepts_after_malformed_body` fails the malformed delivery, asserts `is_process_alive(A2)`, then delivers a valid map body and asserts the receiver reaches `completed`.
- Criterion 6 — pass: `map_body_path_unchanged` drives a full-envelope map body through `build_delivery/2`'s map-with-type-and-payload branch and `send/2`'s map clause, asserts `completed`; the v0.5.6 plain-payload path stays untouched — `soma_actor_message_SUITE` still green and `build_delivery/2:677-684` still wraps a plain payload in the `actor.message` envelope (see Questions).
- Criterion 7 — pass: `docs/contracts/L.2-test-contract.md` maps the suite and all six case names in a table; `test_doc_names_lisp_to_lisp_suite_and_cases` in soma_l2_contract_doc_tests asserts each name present.
- Criterion 8 — pass: `rebar3 eunit` → 182 tests, 0 failures; `rebar3 ct` → All 216 tests passed (both run this review).
- Criterion 9 — pass: `soma_l2_mock_only_tests` asserts every `directive =>` in the suite is `directive => proposal` and counts zero occurrences of `soma_llm_openai`/`api_key`/`base_url`/`api_base`/`http`/`https`; both EUnit checks green.

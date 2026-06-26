### Claude

## Verdict
approve

## Real issues

None.

## Questions

- Criterion 4 and 5 say "leaves the **receiver's** task in failed status." The code fails the **sender's** `actor_message` task — a malformed body fails `soma_lfe:compile/2` at the sender's `send/2` string clause, so no receiver task is ever created. The design documented this reinterpretation (design-107.md:198-204) and the test asserts the sender task fails plus both pids survive. Intent holds (failed as data, no crash, actor lives). Flagging so the reinterpretation is a conscious sign-off, not a slip.
- The design promised to "pin the precedence with a test" for the appended `(correlation-id ...)` winning over one the body already carried (design-107.md:196). No test delivers a Lisp body that already carries its own `(correlation-id ...)`, so last-wins fold order is asserted nowhere. If `parse_msg_fields` ever changes fold direction, the sender's id stops overriding and `by_correlation/2` silently splits the chain. No acceptance criterion requires this, so it's not a blocker — but the documented safety net isn't there.

## Nits

- `soma_l2_mock_only_tests` greps the suite source for the substring `http`. That guards the named file's text, not the runtime, and a stray `http` in a future comment would false-trip it. The by-construction approach is fine for this slice; the literal-substring guard is brittle.

## Functional evidence
- Criterion 1 — pass: `lisp_body_reaches_same_terminal_status_as_map` in soma_actor_lisp_to_lisp_SUITE asserts `completed = LispStatus` and `LispStatus = MapStatus`; suite green (6/6).
- Criterion 2 — pass: `lisp_body_produces_same_step_outputs_as_map` asserts `LispOutputs = MapOutputs` from each receiver's `get_task_result/2`; suite green.
- Criterion 3 — pass: `by_correlation_spans_both_actors_for_lisp_body` reads `soma_event_store:by_correlation(Store, Corr)` and asserts both `actor-a1-corr` and `actor-a2-corr` appear in the event actor_ids; sender appends `(correlation-id ...)` to the Lisp source so the receiver's parsed task lands under A1's id.
- Criterion 4 — pass: `malformed_lisp_body_marks_task_failed` delivers `<<"(msg (type chat) (payload \"hi\"">>` (no closing paren), asserts `failed = wait_for_terminal(A1, <<"task-l2-bad">>, 100)` and both pids alive. Note: failed task is the sender's (see Questions).
- Criterion 5 — pass: `actor_alive_and_accepts_after_malformed_body` fails the malformed delivery, asserts `is_process_alive(A2)`, then delivers a valid map body and asserts the receiver reaches `completed`.
- Criterion 6 — pass: `map_body_path_unchanged` drives a full-envelope map body through `build_delivery/2`'s map branch and `send/2`'s map clause, asserts `completed = Status`; v0.5.6 plain payloads still hit the `actor.message` wrapper branch (verified in soma_actor.erl:677-684).
- Criterion 7 — pass: `docs/contracts/L.2-test-contract.md` maps the suite and all six case names; `test_doc_names_lisp_to_lisp_suite_and_cases` in soma_l2_contract_doc_tests asserts each name present.
- Criterion 8 — pass: `rebar3 eunit` → 182 tests, 0 failures; `rebar3 ct` → All 216 tests passed.
- Criterion 9 — pass: `soma_l2_mock_only_tests` asserts every `directive =>` in the suite is `directive => proposal` and counts zero occurrences of `soma_llm_openai`/`api_key`/`base_url`/`api_base`/`http`/`https`; both EUnit checks green.

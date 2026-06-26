### Claude

## Verdict
changes-requested

## Real issues

1. **A malformed step sub-form crashes the parser instead of returning a diagnostic.**
   `parse_msg_step/2` (`apps/soma_lfe/src/soma_lfe_parser.erl:70`) has clauses
   only for `[]`, `(id ...)`, `(tool ...)`, and `(args ...)`. Any other step
   child throws `function_clause`. Same for `parse_msg_steps/2` (line 60): a
   `steps` body that isn't a `(step ...)` list crashes.

   Proof:
   ```
   soma_lfe:compile(<<"(msg (type chat) (payload \"hi\") (steps (step (id s1) (tool echo) bogus)))">>, #{})
   => {'EXIT', {function_clause, [{soma_lfe_parser,parse_msg_step,...}]}}

   soma_lfe:compile(<<"(msg (type chat) (payload \"hi\") (steps bogus))">>, #{})
   => {'EXIT', {function_clause, [{soma_lfe_parser,parse_msg_steps,...}]}}
   ```
   `parse_msg_fields/2`, `parse_run/1`, and `parse_step_children/3` all carry
   catch-all clauses that produce a diagnostic. The two `msg`-step functions
   don't. The parser advertises `{ok, _} | {error, [diagnostic()]}` and breaks
   that contract.

2. **The crash surfaces in the `send/2` / `ask/3` caller as an `'EXIT'`, not `{error, _}`.**
   `soma_actor:send/2` (`apps/soma_actor/src/soma_actor.erl:37`) runs
   `soma_lfe:compile/2` in the caller's process before `gen_statem:call`. A
   malformed-step Lisp string kills the caller:
   ```
   soma_actor:send(Pid, <<"(msg (type chat) (payload \"hi\") (steps (step (id s1) (tool echo) bogus)))">>)
   => {'EXIT', {function_clause, ...}}
   ```
   Criterion 7 says a malformed Lisp `send/2` returns `{error, _}`. For this
   class of malformed input it returns nothing — it crashes the caller. The
   criterion's own test only feeds unbalanced parens, which the reader catches
   upstream, so the gap is untested and green. Add the malformed-step-sub-form
   case to `test_malformed_lisp_send_actor_survives` once the parser returns a
   diagnostic.

## Questions

- Nested payload `(payload (goal "x"))` returns `{ok, #{payload => [goal, <<"x">>]}}`,
  not a diagnostic. `design-103.md` (lines 58-63) says a nested payload is "a
  diagnostic for now" — the code accepts it and stores the raw list. Not a
  criterion, but the code and the design disagree. Decide which is right and make
  one match the other.

## Nits

- `parse_msg/1` is exported (`soma_lfe_parser.erl:5`) but only ever reached
  through `soma_lfe:dispatch/1`. `parse_run/1` is exported the same way, so this
  is consistent with the existing module — leave it or trim both, not one.

## Functional evidence
- Criterion 1 — pass: `test_msg_form_produces_envelope_map` (`soma_lfe_message_tests`) asserts `compile/2` of the `(msg (type chat) (payload "hi") (steps (step (id s1) (tool echo) (args (value "hi")))))` string equals `#{type => chat, payload => <<"hi">>, steps => [#{id => s1, tool => echo, args => #{value => <<"hi">>}}]}`. EUnit green.
- Criterion 2 — pass: `test_msg_form_carries_correlation_id_and_llm` asserts `correlation_id => <<"c-1">>` and `llm => #{provider => <<"openai">>, model => <<"gpt-4">>}` land in the envelope. EUnit green.
- Criterion 3 — fail: the named examples (unknown sub-form, missing payload) return diagnostics and pass, but a malformed step sub-form (`(step (id s1) (tool echo) bogus)`) and a malformed `steps` body (`(steps bogus)`) throw `function_clause` instead of `{error, [Diagnostic]}`. The "no crash" property does not hold across malformed `(msg ...)` forms. See Real issue 1.
- Criterion 4 — pass: `test_run_form_unchanged_after_msg_added` asserts `(run (step s1 echo (args (value "hi"))))` still returns `{ok, #{run => #{steps => [...]}}}`. `dispatch/1` routes non-`msg` heads to `parse_run/1` unchanged. EUnit green.
- Criterion 5 — pass: `test_lisp_send_matches_map_send_outputs` (`soma_actor_lisp_message_SUITE`) drives the same echo step through Lisp `send/2` and map `send/2` on one actor, asserts equal `get_task_result/2` outputs. CT green (5/5).
- Criterion 6 — pass: `test_lisp_send_correlation_chain_matches_map` drives both forms under disjoint correlation ids, asserts equal `by_correlation/2` event-type chains. CT green.
- Criterion 7 — fail: `test_malformed_lisp_send_actor_survives` passes for unbalanced parens (caught by the reader), but a malformed-step Lisp string crashes the `send/2` caller with `{'EXIT', {function_clause, ...}}` rather than returning `{error, _}`. The criterion holds only for reader-level malformation, not parser-level. See Real issue 2.
- Criterion 8 — pass: `test_lisp_ask_matches_map_ask_result` asserts Lisp `ask/3` and map `ask/3` return equal `{ok, Result}`. CT green.
- Criterion 9 — pass: `test_map_send_path_untouched` sends a plain map envelope, asserts status `completed` and `actor.task.completed` in the correlation chain; `send/2`'s `is_map` clause never calls `soma_lfe`. CT green.
- Criterion 10 — pass: `docs/contracts/L.1-test-contract.md` maps all ten proofs to suite and case; `soma_l1_contract_doc_tests` asserts both suite names and all nine case names appear in the doc. EUnit green.

## Current state

`ask_actor` is registered by `soma_actor_app` as an `erlang_module` tool backed
by `apps/soma_actor/src/soma_tool_ask_actor.erl`. Its input normalizer accepts
only the existing `#{target := StableName, envelope := Envelope}` form. It
looks up the stable actor name, stamps the parent `correlation_id` into the
envelope, calls `soma_actor:ask/3`, and returns the target result unchanged.
That preserves the #213 T.4 contract but leaves no shorthand for a run step that
has only a message body to send to a configured actor.

The runtime step contract already has enough wiring for the Docmod path without
new projection semantics. `soma_run:resolve_args/2` can replace a field value
such as `message => {from_step, read}` with the whole prior output, and
`file_write` can receive `bytes => {from_step, ask}`. Therefore the required
`file_read -> ask_actor -> file_write` flow only needs the shorthand
`ask_actor` step to return a binary reply text. Nested `from_step` substitution
and field projection can stay out of scope.

`soma_actor:build_call_opts/2` already builds real-provider calls from the
actor's `model_config`, deriving one user message from
`Envelope.payload.prompt`. Planning mode (`plan => true`) prepends one planning
system message before that user message. A fixed `response` in the provider
config keeps tests hermetic because `soma_llm_openai:chat/1` parses it directly
and opens no socket. The same builder does not currently add an actor-owned
custom `system_prompt`, and its mock branch always returns the envelope's `llm`
map rather than using a mock directive stored on the actor's `model_config`.

The existing test surfaces fit this issue:

- `apps/soma_actor/test/soma_tool_ask_actor_SUITE.erl` already proves
  end-to-end `ask_actor` run-step behavior, worker boundaries, parent
  correlation, failures, and teardown.
- `apps/soma_actor/test/soma_actor_call_opts_tests.erl` already pins the pure
  provider call-option builder, including planning message ordering and catalog
  prompt behavior.
- `docs/contracts/tool-ask-actor-test-contract.md` already maps the #213
  `ask_actor` contract to tests and should be extended for #219.

`agents/architect.md` is not present in this worktree; the design uses the
schema named in the dispatch prompt and matched by existing `design-*.md`
artifacts.

## Approach

Keep the runtime step format unchanged and add the new behavior at the existing
actor/tool edges.

Extend `soma_tool_ask_actor:normalize_input/1` to return an execution mode in
addition to the stable name and envelope. The existing
`#{target, envelope}` form stays a passthrough mode and must keep returning the
target actor result exactly as it does today. The new shorthand form is
`#{target := StableName, message := Message}` where `StableName` and `Message`
are binaries. It builds:

```erlang
#{type => <<"ask">>,
  payload => #{prompt => Message},
  llm => #{}}
```

The empty `llm` map is intentional: it selects the actor's decision path while
letting the target actor's own `model_config` choose the real provider,
planning mode, custom system prompt, or mock directive. If the input carries
both `message` and `envelope`, fail closed with a named
`{invalid_ask_actor_input, message_and_envelope}` error. If shorthand
`message` is present but is not a binary, return exactly
`{invalid_ask_actor_input, invalid_message}`. Preserve the existing target and
envelope validation errors for the old form.

In `soma_tool_ask_actor:ask_actor/3`, unwrap only shorthand reply proposals.
For shorthand mode, `{ok, #{kind := reply, text := Text}}` becomes `{ok, Text}`.
For shorthand mode with any other `{ok, Result}`, return `{ok, Result}`
unchanged. For the existing envelope mode, keep `{ok, Result}` unchanged even
when `Result` is a `reply` proposal, so #213 callers are not silently changed.
All `{error, Reason}` and `timeout` behavior stays on the existing paths.

Update `soma_actor:build_call_opts/2` in two narrow ways:

- For mock configs, when `model_config` is a map carrying `directive` and the
  envelope's `llm` map is empty or absent, use the actor-owned `model_config` as
  the worker opts. If the envelope supplies a non-empty `llm` map, keep the
  current explicit-envelope behavior. This lets a configured target actor drive
  the mock LLM directive path from shorthand without a provider socket.
- For real-provider configs, support an optional binary `system_prompt` in
  `model_config`. Build the base message list as custom system prompt, then any
  planning system prompt, then the user prompt. With no `system_prompt`, the
  current non-planning and planning message lists stay unchanged. Do this in
  `soma_actor`, not `soma_llm_openai`, because the actor owns policy/planning
  context and the provider should continue to receive already-shaped messages.

Do not put provider secrets or full model config into events. The new
`system_prompt` is request content, not event payload, and existing event
emission should continue to record only ids and bounded status data.

## Acceptance criteria → tests

- A `soma_agent_session:start_run/2` run with
  `file_read -> ask_actor -> file_write` shorthand writes the target actor reply
  text to the output file: add
  `soma_tool_ask_actor_SUITE:ask_actor_shorthand_file_read_to_file_write_writes_reply_text`.
  Start `soma_actor`, start a target actor with stable name and mock directive
  `model_config => #{directive => proposal, output => #{kind => reply, text => <<"model reply">>}}`,
  run steps `read` (`file_read`), `ask` (`ask_actor` with
  `message => {from_step, read}`), and `write` (`file_write` with
  `bytes => {from_step, ask}`), then assert the output file bytes equal
  `<<"model reply">>` and the parent session stays alive.
- A shorthand `ask_actor` call reaches the mock LLM directive path without a
  provider socket: add
  `soma_tool_ask_actor_SUITE:ask_actor_shorthand_uses_actor_mock_model_config_no_socket`.
  Use a target actor whose `model_config` carries a mock `directive`, call
  shorthand with only `target` and `message`, assert the parent step output is
  the reply text and the target task trail includes `llm.started`,
  `llm.succeeded`, and `proposal.created` with no real-provider config needed.
- A shorthand `ask_actor` call returns a non-`reply` target result unchanged:
  add
  `soma_tool_ask_actor_SUITE:ask_actor_shorthand_non_reply_result_unchanged`.
  Use a target actor mock `success` directive returning an opaque map such as
  `#{raw => <<"kept">>}` and assert the parent step output is exactly that map.
- An `ask_actor` input with `message` plus `envelope` fails with an
  `invalid_ask_actor_input` error: add
  `soma_tool_ask_actor_SUITE:ask_actor_message_and_envelope_rejected`.
  Start a parent session run whose `ask_actor` args carry both fields, assert
  terminal `run.failed` and a reason matching
  `{invalid_ask_actor_input, message_and_envelope}`, and assert the session can
  run a later echo step.
- An `ask_actor` shorthand input with a non-binary `message` fails with
  `{invalid_ask_actor_input, invalid_message}`: add
  `soma_tool_ask_actor_SUITE:ask_actor_shorthand_non_binary_message_rejected`
  with `message => #{bad => value}` or an integer, then assert the exact
  failure reason and follow-up session liveness.
- A real-provider `model_config` with `system_prompt` places a first `system`
  message before the user prompt: add
  `soma_actor_call_opts_tests:real_provider_system_prompt_precedes_user_message_test`.
  Call `soma_actor:build_call_opts/2` with `provider => openai_compat` and
  `system_prompt => <<"custom">>`, then assert `messages` is
  `[#{role => <<"system">>, content => <<"custom">>},
    #{role => <<"user">>, content => Prompt}]`.
- A planning real-provider `model_config` with `system_prompt` orders messages
  as custom system prompt, planning system prompt, user prompt: add
  `soma_actor_call_opts_tests:planning_system_prompt_orders_custom_then_planning_then_user_test_`.
  Run under the existing tool-registry fixture, set `plan => true` and
  `system_prompt => <<"custom">>`, then assert the first message content is the
  custom prompt, the second system message contains `(run-steps`, and the final
  message is the original user prompt.
- `docs/contracts/tool-ask-actor-test-contract.md` maps each issue #219 proof
  to its test case: extend that contract with a #219 section naming every test
  above, and add an EUnit doc guard such as
  `soma_tool_ask_actor_contract_tests:issue_219_contract_names_all_proofs_test`
  that reads the markdown and asserts every new suite/module and case name is
  present.

## Risks & trade-offs

- The biggest compatibility risk is reply unwrapping. Limiting unwrapping to
  shorthand mode preserves the existing `#{target, envelope}` behavior while
  giving Docmod the binary output it needs for `file_write`.
- Letting a mock directive live on actor `model_config` is additive but changes
  the empty-`llm` mock case from "worker crashes with function_clause" to
  "configured actor handles the request." Explicit envelope `llm` maps should
  keep precedence so current CLI and direct actor tests remain stable.
- `system_prompt` ordering must be deterministic. Insert the custom prompt
  before planning's generated prompt so operator policy comes first, while the
  planning instruction still remains adjacent to the user request and catalog.
- Shorthand creates an `llm` envelope, not a `steps` envelope. That is the right
  boundary for asking a configured actor, but it means a target actor without
  any usable provider or mock directive should still fail as target task data,
  not cause `ask_actor` to invent model behavior.
- The end-to-end file proof depends on whole-output `from_step` only. Do not add
  nested projection to make tests pass; the ask step's output must already be the
  reply text binary.

# node B.2: actor builds real-provider call opts from model_config

## Current state

`soma_actor` already starts and owns an `soma_llm_call` worker per task. The
`llm` opts it hands the worker come straight off the envelope:
`maybe_start_llm_call/4` reads `maps:get(llm, Envelope, undefined)` and passes
that map verbatim into `start_llm_call/4`, which calls
`soma_llm_call:start(#{owner, llm_call_id, llm => Llm})`. The worker's
`perform_call/1` then routes on what is in that map — opts carrying
`provider => openai_compat` reach `soma_llm_openai:chat/1`, opts carrying a
`directive` stay on the mock.

node B.1 (#101) built the real provider and that routing. `soma_llm_openai:chat/1`
already honors a fixed `response` seam: a config carrying `response => {Status, Body}`
parses that pair directly and opens no socket, the same seam B.1's gate test used.

The actor stores a `model_config` field in `#data` (`init/1` reads
`maps:get(model_config, Opts, undefined)`) but never reads it again. So the only
thing that decides mock vs real is what the *caller* puts in the envelope's `llm`
field. An actor configured at startup with a real provider can't drive a real
call — there is no code path from `model_config` to the worker opts. That gap is
what CLI.2 (`soma ask`) needs closed: `soma ask` starts an actor with a provider
config, then sends it a plain prompt, and expects a real call.

## Approach

Add a pure builder on `soma_actor` that turns the actor's `model_config` plus the
incoming envelope into the `llm` opts the worker runs. Call it from
`start_llm_call/4` (or `maybe_start_llm_call/4`) so every started call goes
through it. The builder is the whole of B.2's logic; the worker and the provider
module are untouched.

The builder branches on `model_config`:

- A real-provider config `#{provider => openai_compat, base_url => B, model => M}`
  becomes opts carrying `provider => openai_compat`, that `base_url` and `model`,
  an `api_key`, and a `messages` list. `perform_call/1` then routes to
  `soma_llm_openai`. The `messages` list is derived from the envelope payload:
  one user message holding the prompt the payload carries. Kept minimal on
  purpose — one message, no system prompt, no history.
- An empty `model_config` (or one carrying a `directive`) returns the envelope's
  `llm` map unchanged, so the mock path the actor drives today is byte-for-byte
  what it was. This keeps every v0.5 / L.x suite green without re-pinning.

The decision rests on a single key. A `model_config` with `provider => openai_compat`
is the real path; anything else (empty, or `directive`-shaped) is the mock path.
This is the same `provider` key `perform_call/1` already matches on, so the actor
and the worker agree on one switch.

For the real-provider production test (criterion 4) the actor must reach
`soma_llm_openai:chat/1` without a socket. The fixed `response` seam B.1 exposes
is how: a real-provider `model_config` in the test carries a `response` field,
the builder threads it into the opts, `chat/1` parses it directly, and the parsed
`reply` proposal flows back through the actor's existing `proposal_result/2` →
normalize → policy path to the task result. No new test-only branch in
production code — `response` is a field the builder copies through, the same way
`base_url` and `model` are.

The `api_key` is part of the real-provider `model_config` but must never land in
an event. The actor's events already carry only `task_id`, `correlation_id`,
`llm_call_id`, and `llm_call_pid` — none of the `llm` opts. So keeping the key
out of events is a matter of not adding it to any `emit/3` payload, and the test
asserts that holds for a real-provider task.

`docs/usage.md` gains a section on starting an actor with a real-provider
`model_config` and sending it a prompt envelope, next to the existing
"Configuring a real LLM provider" section that documents the provider module and
the smoke test.

## Acceptance criteria → tests

### Criterion 1 — builder turns a real-provider model_config into routing opts
- Call chain: none (direct function call) — `soma_actor:build_call_opts/2`
  (exact name the implementer's choice) is a pure exported function the test
  calls directly with a `model_config` and an envelope.
- Test entry: `soma_actor:build_call_opts/2`. The test asserts the returned opts
  carry `provider => openai_compat`, the config's `base_url`, and its `model` —
  the keys `soma_llm_call:perform_call/1` routes on.
- Test: `test_real_provider_model_config_builds_routing_opts` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl`

### Criterion 2 — builder derives a user message from the envelope prompt
- Call chain: none (direct function call) — same pure builder.
- Test entry: `soma_actor:build_call_opts/2`, given a real-provider config and an
  envelope whose payload carries a prompt. The test asserts the opts' `messages`
  is a non-empty list holding that prompt as a user message.
- Test: `test_real_provider_opts_carry_prompt_as_user_message` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl`

### Criterion 3 — empty or directive model_config returns the mock opts unchanged
- Call chain: none (direct function call) — same pure builder.
- Test entry: `soma_actor:build_call_opts/2`, called once with an empty
  `model_config` and once with a `directive`-shaped one. The test asserts the
  returned opts equal the envelope's `llm` map unchanged.
- Test: `test_empty_or_directive_model_config_returns_mock_opts_unchanged` in
  `apps/soma_actor/test/soma_actor_call_opts_tests.erl`

### Criterion 4 — real-provider actor drives an llm task through soma_llm_openai, no socket
- Call chain: `soma_actor:send/2` → `idle/3` `{send, Envelope}` →
  `maybe_start_llm_call/4` → `build_call_opts/2` → `start_llm_call/4` →
  `soma_llm_call:start/1` → `perform_call/1` (`provider => openai_compat` clause)
  → `soma_llm_openai:chat/1` (the fixed `response` seam) → `parse_response/1` →
  `{llm_result, ...}` back to `idle/3` → `proposal_result/2` → task result
- Test entry: `soma_actor:send/2` (no layer bypassed). The actor is started with
  a real-provider `model_config` that carries a fixed `response`; the test reads
  the task result back through `get_task_result/2` and asserts it is the parsed
  `reply` proposal. No socket opens because the `response` seam short-circuits
  `httpc`.
- Test: `real_provider_actor_completes_llm_task_through_openai_no_socket` in
  `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl`

### Criterion 5 — empty or mock model_config still completes through the mock, same result and events
- Call chain: `soma_actor:send/2` → `idle/3` → `maybe_start_llm_call/4` →
  `build_call_opts/2` (mock branch, opts unchanged) → `start_llm_call/4` →
  `soma_llm_call:start/1` → `perform_call/1` (directive clause) →
  `{llm_result, ...}` → task result
- Test entry: `soma_actor:send/2`. The actor is started with an empty (or
  `directive`-shaped) `model_config` and sent the same `success` / `proposal`
  mock envelope the v0.5 suite uses. The test asserts the task result and the
  `by_correlation/2` event set match the v0.5 mock behaviour.
- Test: `mock_model_config_completes_llm_task_same_result_and_events` in
  `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl`

### Criterion 6 — api_key appears in no event the actor emits for the task
- Call chain: `soma_actor:send/2` → the full real-provider chain of criterion 4,
  emitting `actor.*` / `llm.*` events along the way
- Test entry: `soma_actor:send/2` with a real-provider `model_config` whose
  `api_key` is a known sentinel binary. After the task completes the test pulls
  every event under the task's `correlation_id` through `by_correlation/2` and
  asserts the sentinel appears in none of their payloads.
- Test: `api_key_appears_in_no_emitted_event` in
  `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl`

### Criterion 7 — the gate suite opens no real-provider network connection
- Call chain: none (direct source-file read) — the test reads the real-provider
  suite source and asserts what it does and does not do.
- Test entry: off chain — this is a by-construction guard, like
  `soma_l5_mock_only_tests`. The reason it reads source rather than running the
  suite: it pins that no case reaches the live `httpc` path. It asserts the suite
  reaches `soma_llm_openai` only through a `response` seam (the marker
  `response =>` is present and gates every real-provider config) and names no
  network host/port literal (`http://` / `https://` absent).
- Test: `test_real_provider_suite_uses_response_seam_only` in
  `apps/soma_actor/test/soma_b2_no_socket_tests.erl`

### Criterion 8 — usage.md documents real-provider model_config and the smoke
- Call chain: none (direct source-file read).
- Test entry: off chain — a doc-presence guard reads `docs/usage.md` and asserts
  it documents starting an actor with a real-provider `model_config` (the
  `model_config` + `provider => openai_compat` markers appear together in a new
  section) and points at the opt-in smoke.
- Test: `test_usage_documents_actor_real_provider_config` in
  `apps/soma_actor/test/soma_b2_no_socket_tests.erl`

### Criterion 9 — gate green, no socket; dialyzer run and reported
- Call chain: none (build-time / process-level check).
- Test entry: off chain — this is the gate itself. `rebar3 eunit && rebar3 ct`
  must pass and open no socket (criteria 4–7 hold this for the new code);
  `rebar3 dialyzer` is run and its result reported in the PR.
- Test: the gate run (`rebar3 eunit`, `rebar3 ct`, `rebar3 dialyzer`); no
  dedicated case.

## Risks & trade-offs

- The fixed `response` seam means the gate's real-provider proof exercises the
  parse path and the actor's routing, but never the live `httpc` call. A bug that
  only shows up over a real socket — a wrong header, a TLS issue — is caught only
  by the manual smoke test, not the gate. This is the same trade B.1 already
  made; B.2 inherits it rather than widening it.
- The prompt-to-`messages` shaping is one user message with no system prompt and
  no history. That is enough for `soma ask` and no more. A multi-turn or
  system-prompted actor will need a richer builder; this slice deliberately
  doesn't build that.
- Criterion 7's guard reads suite source for the string `response =>` to prove
  the seam is used. A future refactor that renames the seam, or reaches the
  provider a different no-socket way, would trip the guard even though it opens no
  socket. The guard trades some brittleness for a cheap, gate-time proof that no
  live call slipped in.

# CLI.8a: real-provider ask path — intent reaches the model, enable_thinking/max_tokens thread through

## Current state

`soma ask` already routes to a real provider when the daemon's `model_config` carries `provider => openai_compat`. The path is: `soma_cli_server:handle_ask/2` starts a `soma_actor` with that `model_config`, builds an `ask` envelope, and calls `soma_actor:ask/3`. Inside the actor, `maybe_start_llm_call/4` calls `build_call_opts/2`, which turns the `model_config` plus the envelope into the opts `soma_llm_call:perform_call/1` runs. For a real-provider config those opts route to `soma_llm_openai:chat/1`.

Two things break a real ask, and both only show once a real provider is actually driven.

The first is a payload-key mismatch. `handle_ask/2` puts the intent text under `text`:

```erlang
payload => #{text => Intent}
```

But `build_call_opts/2` reads the prompt from `prompt`:

```erlang
Prompt = maps:get(prompt, maps:get(payload, Envelope, #{}), <<>>),
```

So the provider's user message is the empty-binary default. The model gets an empty user message and the intent never arrives.

The second is dropped optional fields. `build_call_opts/2` threads only `[api_key, response]` through `copy_optional/3`:

```erlang
copy_optional([api_key, response], ModelConfig, Opts);
```

`soma_llm_openai:add_optional_opts/1` already copies `enable_thinking` and `max_tokens` from its config into the request body. But those two keys never reach `soma_llm_openai`, because `build_call_opts/2` strips them off the `model_config` before the worker opts are built. A `model_config` that sets `enable_thinking => true` or `max_tokens => N` has no effect on the request body.

Neither bug shows in the current tests. `soma_actor_call_opts_tests` and `soma_actor_real_provider_SUITE` hand-build envelopes with `payload => #{prompt => ...}`, which happens to match the key `build_call_opts/2` reads — so the empty-prompt bug is masked. And no existing test sets `enable_thinking` or `max_tokens` in a `model_config`, so the dropped-fields bug is never exercised.

## Approach

Fix both inside the existing fixed-response seam. No network, no live provider call.

The payload-key mismatch is fixed on the `handle_ask/2` side: rename its `text` key to `prompt`. The open question allows either side; `prompt` wins because `build_call_opts/2` already reads `prompt`, `soma_actor_real_provider_SUITE` and `soma_actor_call_opts_tests` already write `prompt`, and the intent text becoming the user message is the only consumer of that payload field. Nothing else reads `payload.text` — a grep of `apps/soma_actor/src` and `apps/soma_runtime/src` finds the `text` write in `handle_ask/2` and the `prompt` read in `build_call_opts/2`, and no third reader. So the rename is a one-key change with one reader.

The dropped-fields bug is fixed by extending the `copy_optional/3` key list from `[api_key, response]` to `[api_key, response, enable_thinking, max_tokens]`. `copy_optional/3` already copies a key only when the source carries it, so a `model_config` without `enable_thinking` or `max_tokens` leaves those keys off the worker opts unchanged — the existing routing-opts and mock-path tests stay green. Once the two keys reach the worker opts, `soma_llm_openai:add_optional_opts/1` puts them in the request body with no further change.

The mock path is untouched by both fixes. `build_call_opts/2`'s second clause returns the envelope's `llm` map unchanged for a non-real-provider `model_config`, and it never reads the payload — so renaming the payload key does not change what the mock sees. The mock directive opts ride in the envelope's `llm` map, which is independent of the payload.

The test constraint that shapes where proofs live: `soma_cli_server_SUITE.erl` is on the CLI no-network marker scan's include list (`soma_cli_3_marker_tests:cli_3_sources/0`), which bans the strings `api_key`, `base_url`, `http`, `https`, and `soma_llm_openai` in that source. A real-provider `model_config` carries `base_url` and `api_key`, so the real-provider proofs cannot live in the CLI server suite. They go in `soma_actor_call_opts_tests` (the pure-builder unit module) and `soma_actor_real_provider_SUITE` (the actor-through-the-seam CT suite), following the node B.2 precedent. Those two are not on the no-network marker scan's include list — that scan guards the daemon socket test sources, not the provider-seam tests. `soma_actor_real_provider_SUITE` is separately guarded by `soma_b2_no_socket_tests`, which checks every real-provider config in it carries a `response` seam and names no `http://` / `https://` literal; new cases there must keep that property.

## Acceptance criteria → tests

### Criterion 1 — the provider request's user message holds the intent text, not an empty string

The single source of truth is the intent text reaching the provider's user message. Two layers carry it: `handle_ask/2` writes the intent into the payload, and `build_call_opts/2` reads the payload into the user message. The rename lives in `handle_ask/2`, so the proof that matters is the full daemon path, plus a unit proof that the builder reads the renamed key.

- Call chain: gen_tcp client sends `(ask (intent "..."))` → `soma_cli_server:handle_ask/2` (writes intent into `payload => #{prompt => Intent}`) → `soma_actor:ask/3` → `idle/3` ask clause → `maybe_start_llm_call/4` → `build_call_opts/2` (reads `payload.prompt` into the user message)
- Test entry: `soma_actor:build_call_opts/2`. A unit test enters the builder with an envelope whose payload carries `prompt`, asserting the messages list holds that text as the user message — the builder is where the empty-string default would bite. The end-to-end `handle_ask/2` rename is covered by the existing CLI-server ask cases staying green (they cannot assert provider fields without a real-provider marker).
- Test: `test_real_provider_opts_carry_prompt_as_user_message` in `apps/soma_actor/test/soma_actor_call_opts_tests.erl` (already present; the rename keeps it honest — it is the reader-side proof). A new `test_handle_ask_payload_key_matches_build_call_opts_reader` in the same module pins the key both sides agree on, so a future rename on one side without the other is caught.

### Criterion 2 — enable_thinking => true reaches the provider request body

- Call chain: `soma_actor:build_call_opts/2` (copies `enable_thinking` from `model_config` into worker opts) → `soma_llm_call:perform_call/1` (`provider => openai_compat` clause) → `soma_llm_openai:chat/1` → `build_request/1` → `add_optional_opts/1` (puts `enable_thinking` in the body map)
- Test entry: `soma_actor:build_call_opts/2`. The bug is the builder dropping the key, so the test enters at the builder and asserts the returned opts carry `enable_thinking => true`. A second assertion runs `soma_llm_openai:build_request/1` on those opts and decodes the body, proving the key survives all the way into the JSON the provider would receive — no socket, the `response` seam is not needed because `build_request/1` is pure.
- Test: `test_enable_thinking_threads_through_to_request_body` in `apps/soma_actor/test/soma_actor_call_opts_tests.erl`

### Criterion 3 — max_tokens => N reaches the provider request body

- Call chain: `soma_actor:build_call_opts/2` (copies `max_tokens` from `model_config` into worker opts) → `soma_llm_call:perform_call/1` (`provider => openai_compat` clause) → `soma_llm_openai:chat/1` → `build_request/1` → `add_optional_opts/1` (puts `max_tokens` in the body map)
- Test entry: `soma_actor:build_call_opts/2`. Same shape as criterion 2: enter at the builder, assert the opts carry `max_tokens => N`, then run `build_request/1` and decode the body to confirm the value lands in the request JSON.
- Test: `test_max_tokens_threads_through_to_request_body` in `apps/soma_actor/test/soma_actor_call_opts_tests.erl`

### Criterion 4 — a non-real-provider ask produces the same envelope and same result it does today

- Call chain: gen_tcp client sends `(ask (intent "..."))` → `soma_cli_server:handle_ask/2` → `soma_actor:ask/3` → `idle/3` ask clause → `maybe_start_llm_call/4` → `build_call_opts/2` (second clause, returns the envelope's `llm` map unchanged) → `soma_llm_call:perform_call/1` (mock directive clause) → `soma_proposal:normalize/1` → `soma_policy:check/2` → `soma_lisp:render/1`
- Test entry: a gen_tcp client over the local Unix socket (no layer bypassed). The existing CLI-server ask cases drive the mock model_config end to end and assert the rendered `(result ...)`; the rename to `prompt` must not change their outcome, since the mock path ignores the payload. A unit test also pins that `build_call_opts/2` returns the `llm` map unchanged for an empty and a directive-shaped `model_config`.
- Test: `test_ask_reply_returns_completed_result_with_text` and `test_ask_reject_returns_rejected_result_with_reason` in `apps/soma_actor/test/soma_cli_server_SUITE.erl` (existing, must stay green after the rename), plus `test_empty_or_directive_model_config_returns_mock_opts_unchanged` in `apps/soma_actor/test/soma_actor_call_opts_tests.erl` (existing, the builder-side proof)

### Criterion 5 — an API key in a real-provider model_config appears in no event payload and no rendered reply

- Call chain: `soma_actor_sup:start_actor/1` (real-provider `model_config` with a sentinel `api_key` and a fixed `response`) → `soma_actor:send/2` with an `llm` envelope → `idle/3` → `maybe_start_llm_call/4` → `build_call_opts/2` → `soma_llm_call:perform_call/1` → `soma_llm_openai:chat/1` (parses the fixed `response`, no socket) → task reaches `completed`; events read back through `soma_event_store:by_correlation/2`
- Test entry: `soma_actor:send/2` through `soma_actor_sup:start_actor/1` (no layer bypassed). The test scans every emitted event for the sentinel and asserts it is absent. The actor emits ids only, never the key, so the api_key stays off the trail.
- Test: `api_key_appears_in_no_emitted_event` in `apps/soma_actor/test/soma_actor_real_provider_SUITE.erl` (existing). For the "no rendered reply" half — the CLI reply is rendered from the task result (`#{kind => reply, text => Content}`), which never carries the api_key — a new `test_rendered_reply_carries_no_api_key` covering the result-to-`soma_lisp:render/1` shape sits in `soma_actor_real_provider_SUITE.erl` so it can name the real-provider config; the CLI server suite cannot, because of the marker scan.

## Risks & trade-offs

Renaming `handle_ask/2`'s payload key to `prompt` is a behavior change to the wire-internal envelope shape, not the client wire (the client still sends `(ask (intent "..."))`; only the in-process envelope changes). Any out-of-tree code that built an ask envelope with `payload => #{text => ...}` and fed it to `build_call_opts/2` directly would already have been broken — the builder never read `text`. So the rename has no caller to break beyond `handle_ask/2` itself.

Criteria 2 and 3 are proven at the builder plus `build_request/1`, not through a live provider that echoes the body back. That is the cost of staying off the network: the proof is "the key reaches the request JSON", not "the provider honored it". Honoring `enable_thinking` / `max_tokens` is the provider's contract, checked live only by the opt-in `soma_llm_smoke`, which stays off the gate. This matches the node B.1 / B.2 precedent and is the right line for a hermetic gate.

The real-provider proofs are split across two files because the CLI server suite is on the no-network marker scan and cannot carry `api_key` / `base_url`. This keeps the end-to-end ask coverage (mock path) in the CLI suite and the real-provider field coverage in the call-opts unit module and the real-provider CT suite. The downside is that no single test drives a real-provider `model_config` end to end through the socket — that is the marker scan's deliberate trade: the daemon socket sources stay grep-provably network-free.

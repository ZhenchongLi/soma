### Claude

## Verdict
approve

## Real issues
None.

## Questions

- `soma_llm_openai:chat/1` carries a test-only door: `chat(#{response := Response}) -> parse_response(Response)` (soma_llm_openai.erl:68). It exists so the routing tests and the gate's no-socket test build-then-parse over a canned `{Status, Body}` instead of dialing `httpc`. It works, and the gate proves it stays offline. But a production caller that happens to put a `response` key in the config silently skips the real call. The seam tests could inject by mocking `httpc` or by splitting `build_request` + `parse_response` directly (both are exported), keeping `chat/1` a pure live path. Acceptable as-is for this slice; flagging so it doesn't ossify into the provider contract.
- `parse_response/1` catches `error:{badmatch, _}` for the missing-content path and `_:_` for everything else (soma_llm_openai.erl:51-54). `json:decode/1` on a malformed body throws, and the `_:_` clause maps it to `{malformed_response_body, undecodable}` — fine. The two reasons don't distinguish a 200-with-error-JSON from truncated bytes; both land as `unexpected_response_shape` or `malformed_response_body`. Bounded and named, so it meets the criterion. Worth a thought for B.2 if callers need to tell a provider error blob from a transport failure.

## Nits

- `chat/1`'s doc comment (soma_llm_openai.erl:1-6) still says "The impure `httpc` call and `parse_response/1` are later cycles" — stale, both landed in this branch.

## Functional evidence
- Criterion 1 — pass: `build_request/1` sets `Url = <<BaseUrl/binary, "/chat/completions">>` (soma_llm_openai.erl:17); `build_request_url_test` asserts `<<"https://api.example.test/v1/chat/completions">>`.
- Criterion 2 — pass: header `{"Authorization", "Bearer " ++ binary_to_list(ApiKey)}` (soma_llm_openai.erl:18); `build_request_auth_header_test` asserts `{"Authorization", "Bearer dummy-key"}`.
- Criterion 3 — pass: body map `#{model => Model, messages => Messages}` json-encoded (soma_llm_openai.erl:19-21); `build_request_body_has_model_and_messages_test` decodes and asserts both keys present.
- Criterion 4 — pass: `add_optional_opts/2` folds `enable_thinking` and `max_tokens` into the body when present (soma_llm_openai.erl:26-35); `build_request_body_includes_optional_opts_test` asserts both keys in the decoded body.
- Criterion 5 — pass: same fold copies a key only on `{ok, Value}`; `build_request_body_omits_optional_opts_test` asserts neither key present when opts absent.
- Criterion 6 — pass: `parse_response({200, Body})` pulls `choices[0].message.content` to `{ok, #{kind => reply, text => Content}}` (soma_llm_openai.erl:44-49); `parse_response_success_to_reply_test` asserts `{ok, #{kind => reply, text => <<"Hello from the model.">>}}`.
- Criterion 7 — pass: non-200 -> `{error, {http_status, Status}}`; bad shape -> `{error, {unexpected_response_shape, missing_content}}`; undecodable -> `{error, {malformed_response_body, undecodable}}` (soma_llm_openai.erl:50-57); `parse_response_bounded_errors_test` drives 500, error-JSON, and `{not json` and asserts `{error, _}` for each, no crash.
- Criterion 8 — pass: directive clauses unchanged (soma_llm_call.erl:39-68); `perform_call_directive_unchanged_test` asserts `{ok, Output}` for `#{directive => success, output => Output}`.
- Criterion 9 — pass: `perform_call(#{provider := openai_compat} = Opts) -> soma_llm_openai:chat(Opts)` (soma_llm_call.erl:34-35); `perform_call_routes_to_openai_test` drives a provider map and asserts `{ok, #{kind => reply, text => <<"routed reply">>}}`.
- Criterion 10 — pass: `reply_proposal_normalizes_test` runs the parsed proposal through `soma_proposal:normalize/1` and asserts `{ok, _}`; matches the `normalize(#{kind := reply, text := Text})` clause (soma_proposal.erl:14).
- Criterion 11 — pass: `{applications, [kernel, stdlib, inets, ssl, soma_event_store, soma_tools]}` (soma_runtime.app.src:6); `app_src_lists_inets_and_ssl_test` consults the app.src and asserts both members.
- Criterion 12 — pass: `soma_llm_smoke:run/0` reads `SOMA_LLM_API_KEY`, starts inets/ssl, calls SophNet `DeepSeek-V3` through `soma_llm_openai:chat/1`, prints the reply proposal (soma_llm_smoke.erl:28-40); plain `src/` module, no `*_test`/`*_SUITE` name, off both runners.
- Criterion 13 — pass: docs/usage.md "Configuring a real LLM provider" section (lines 754-819) documents `openai_compat`, key from `SOMA_LLM_API_KEY`, base_url/model from config, and `soma_llm_smoke:run()`; `usage_docs_real_provider_and_smoke_test_test` asserts each substring.
- Criterion 14 — pass: `rebar3 eunit` -> 169 tests, 0 failures; `rebar3 ct` -> All 198 tests passed. The gate's provider tests pass a canned `response` so the routing path never reaches `httpc`; `perform_call_routing_opens_no_socket_test` points base_url at unroutable 192.0.2.1 (TEST-NET-1) and still returns the parsed reply, falsifying any socket attempt.

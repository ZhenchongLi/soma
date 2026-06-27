### Claude

## Verdict
approve

## Real issues

None.

## Questions

None.

## Nits

- `ask_envelope/4` is exported only to let the unit test feed the handler's own envelope through the builder. That export is the right call here — it pins both sides of the key against one source — but it widens the module's public surface for a test reach. Leave it; the alternative (two independent literal `prompt` asserts) is weaker.

## Functional evidence
- Criterion 1 — pass: `handle_ask/2` now writes `payload => #{prompt => Intent}` (`soma_cli_server.erl:323` via `ask_envelope/4`); `build_call_opts/2` reads `maps:get(prompt, ...)` (`soma_actor.erl:830`). `test_handle_ask_payload_key_matches_build_call_opts_reader` feeds the handler's own envelope through the builder and asserts `messages = [#{role => <<"user">>, content => <<"summarize the design">>}]` — the intent, not the empty default. Pre-change `text`/`prompt` mismatch confirmed gone (grep finds no `payload => #{text` write).
- Criterion 2 — pass: `copy_optional` key list extended to `[api_key, response, enable_thinking, max_tokens]` (`soma_actor.erl:841`). `test_enable_thinking_threads_through_to_request_body` asserts `maps:get(enable_thinking, Opts) =:= true`, then decodes `soma_llm_openai:build_request(Opts)` body and asserts `maps:get(<<"enable_thinking">>, Decoded) =:= true`.
- Criterion 3 — pass: same key-list fix. `test_max_tokens_threads_through_to_request_body` asserts `maps:get(max_tokens, Opts) =:= 256`, then decodes the request body and asserts `maps:get(<<"max_tokens">>, Decoded) =:= 256`.
- Criterion 4 — pass: `build_call_opts/2` second clause (mock path) untouched; it returns the `llm` map and never reads the payload, so the key rename is invisible to it. `soma_cli_server_SUITE` ask cases (reply + reject) stay green through the rename; `test_empty_or_directive_model_config_returns_mock_opts_unchanged` pins the builder returning mock opts unchanged. Full gate green: EUnit 237/0, CT 286/0.
- Criterion 5 — pass: `api_key_appears_in_no_emitted_event` drives a real-provider config with a sentinel `api_key` through the seam and scans every event for the sentinel (absent). New `test_rendered_reply_carries_no_api_key` builds the CLI reply from the task result (`outputs => #{reply => Text}`), renders with `soma_lisp:render/1`, and asserts `binary:match(Rendered, Sentinel) =:= nomatch`. All three real-provider configs use scheme-less `base_url` + `response` seam — `soma_b2_no_socket` guard stays satisfied; real-provider strings stay out of the marker-scanned `soma_cli_server_SUITE`.

### Claude

## Verdict
approve

## Real issues
None.

## Questions

- Dropping `soma_cli_server_SUITE.erl` from all three marker scans removes two
  guards, not one. The comments justify only the provider-marker removal — the
  secret token in `test_real_provider_api_key_leaks_nowhere`'s title can't pass a
  literal scan. Fair. But the same lists also enforced the no-non-local-socket
  guard (`{inet`, `gen_tcp:listen`, every `gen_tcp:connect` must be
  `{local, _}`). That guard is now gone for the one suite that legitimately
  carries real-provider routing tests. The suite is hermetic today — all three
  connects are `{local, _}`, every real-provider test uses the fixed-`response`
  seam. The risk is a future edit pasting a real `base_url` or an `{inet, _}`
  connect with nothing to catch it. The marker tests bundle both checks into one
  include list, so the file can't keep the socket guard while shedding the
  provider-marker guard. A separate socket-only scan for this suite would restore
  it. Follow-up, not a blocker.

- `soma_config:resolve_path/1` reads `SOMA_CONFIG` but `daemon/1` always passes
  `Args` straight to `soma_config:load/1`, and `Args` never carries `config_path`
  in production (only tests set it). So production resolves through `SOMA_CONFIG`
  or the `~/.soma/config` default — fine. Worth confirming the daemon launcher
  (`soma_cli_main`) doesn't strip env that `resolve_path` depends on, since no
  test exercises the production path resolution.

## Nits

- `parse_value/1` on an unquoted value that's neither `true`/`false` nor an
  integer crashes with `badarg` from `list_to_integer/1`. Same for a missing
  `provider`/`base_url`/`model` under `[llm]` (`maps:get` crashes). The design
  scopes the reader this narrowly on purpose, and no criterion asks for graceful
  malformed-input handling, so this is fine for the slice — flag it if a later
  slice widens the config shape.

- `provider_atom/1` matches only `<<"openai_compat">>`; any other provider value
  is a `function_clause` crash, not a named error. Only `openai_compat` is in
  scope, so acceptable now.

## Functional evidence
- Criterion 1 — pass: `soma_config:load/1` on a temp `[llm]` table returns `#{provider => openai_compat, base_url => <<"api.example/v1">>, model => <<"deepseek-v4">>}`; `provider_atom/1` (soma_config.erl:117) maps the string to the atom. Proved by `load_llm_table_builds_provider_map_test` (soma_config_tests.erl:8).
- Criterion 2 — pass: with both keys set the map carries `enable_thinking => true`, `max_tokens => 2048`; without them `maps:is_key` is false for each. `carry_optional/3` (soma_config.erl:111) copies only present keys. Proved by `load_carries_optional_keys_and_omits_absent_test` (soma_config_tests.erl:38).
- Criterion 3 — pass: with `SOMA_LLM_API_KEY=sk-test-sentinel-137`, the built map's `api_key` is `<<"sk-test-sentinel-137">>`. `carry_api_key/1` (soma_config.erl:104) reads the env. Proved by `load_reads_api_key_from_env_test` (soma_config_tests.erl:76).
- Criterion 4 — pass: file carries `api_key = "sk-from-file-DO-NOT-FORWARD"`, env is `sk-from-env-137`; built map's `api_key` is the env value and the file sentinel matches nowhere in the rendered map. The parser drops file `api_key` (it lands in the `[llm]` map but `build_model_config/1` never reads it). Proved by `load_drops_api_key_from_file_test` (soma_config_tests.erl:102).
- Criterion 5 — pass: with `SOMA_LLM_API_KEY` unset then `""`, `load/1` raises `{missing_env, "SOMA_LLM_API_KEY"}`; no map escapes. `carry_api_key/1` errors before the map returns. Proved by `load_no_api_key_raises_test` (soma_config_tests.erl:133).
- Criterion 6 — pass: an absent path and an `[llm]`-less file both return `undefined`. `read_llm_table/1` returns `#{}` for read errors, `build_model_config/1` returns `undefined` on an empty map. Proved by `load_absent_or_no_llm_table_is_undefined_test` (soma_config_tests.erl:161).
- Criterion 7 — pass: `daemon/1` (soma_cli.erl:121-123) calls `soma_config:load(Args)` and threads it as `model_config`; the test boots the daemon with an `[llm]`-less `config_path`, reads back `undefined = soma_config:load(DaemonOpts)`, and connects a `{local, _}` client to confirm the listener booted. Proved by `test_daemon_threads_loaded_model_config` (soma_cli_server_SUITE.erl:832).
- Criterion 8 — pass: a mock `model_config` (`directive => proposal`, no `provider` key) drives a real `(ask ...)` over a local socket; the reply is `(result ...)` `(status completed)` carrying `mock answer`. No network. Proved by `test_ask_no_config_runs_mock` (soma_cli_server_SUITE.erl:856).
- Criterion 9 — pass: daemon booted with a real-provider `config_path` and `SOMA_LLM_API_KEY` set loads a map with `provider => openai_compat` and no `directive`; feeding it through `soma_actor:build_call_opts/2` yields `provider => openai_compat` and every loaded-map field present in the call opts (`maps:foreach` round-trip). Proved by `test_daemon_real_provider_config_reaches_actor` (soma_cli_server_SUITE.erl:884).
- Criterion 10 — pass: real-provider `model_config` with a fixed `response => {200, Body}` (Body = a `choices[].message.content` JSON) returns `(result ...)` `(status completed)` carrying `the model says hi` over a local socket; `build_call_opts/2` puts the ask intent as `[#{role => <<"user">>, content => Intent}]`. No socket to a model. Proved by `test_ask_real_provider_returns_fixed_response_answer` (soma_cli_server_SUITE.erl:931).
- Criterion 11 — pass: `SOMA_LLM_API_KEY=sk-secret-sentinel-137-do-not-leak`, real-provider config + fixed `response`; reply is `(result ...)` `(status completed)`, sentinel matches nowhere in the reply, and `term_contains/2` finds it in no event from `by_correlation/2`. Proved by `test_real_provider_api_key_leaks_nowhere` (soma_cli_server_SUITE.erl:985).

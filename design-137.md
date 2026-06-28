# [cc] CLI.8b: ~/.soma/config (TOML) -> daemon model_config, real provider for soma ask

## Current state

The daemon starts the listener with no model config. `soma_cli:daemon/1`
(`apps/soma_actor/src/soma_cli.erl:118`) boots the runtime, resolves the socket
path, and calls `soma_cli_server:start_link(#{socket => Path})`. There is no
`model_config` key in that map, so `soma_cli_server` defaults it to `undefined`
(`apps/soma_actor/src/soma_cli_server.erl:25`).

With `model_config => undefined`, `handle_ask/2` builds the ask envelope's `llm`
map from `mock_llm_opts(undefined)`, which returns `#{}`
(`soma_cli_server.erl:330-333`). The actor's `build_call_opts/2` then takes its
non-real-provider branch and returns that empty map unchanged
(`soma_actor.erl:847`), so every `soma ask` runs the mock. There is no path for
the daemon to drive a real model.

The real-provider routing is already built. CLI.8a landed `build_call_opts/2`'s
`openai_compat` branch (`soma_actor.erl:827`), which threads `base_url`, `model`,
`api_key`, the fixed `response` seam, `enable_thinking`, and `max_tokens` into
the worker opts that reach `soma_llm_openai`. The fixed `response` short-circuits
`soma_llm_openai:chat/1` so it parses a `{Status, Body}` pair and opens no
socket. So once the daemon hands the actor a real-provider `model_config`, the
ask path already returns the configured model's answer with no further wiring.

What is missing is the piece that turns a config file into that `model_config`.
There is no `soma_config` module and no reader for `~/.soma/config`.
`docs/cli.md:354` only notes the file's intended location and that the key comes
from the daemon's env.

## Approach

Add `soma_config` in `apps/soma_actor/src/`. It owns two jobs: parse the tiny
TOML subset, and assemble the `model_config` map the actor consumes. The
runtime never imports it, so the one-way dependency holds.

`soma_config:load/1` takes an options map and returns the `model_config` map or
`undefined`. The path comes from the options under a `config_path` key when the
caller supplies one (the hermetic-test seam), else from the `SOMA_CONFIG` env
var, else the `$HOME`-expanded `~/.soma/config` default. Picking one explicit
override key (`config_path`) plus the `SOMA_CONFIG` env keeps the test seam and
the production default both reachable; the open question left this to the
architect.

Parsing is a hand-rolled TOML-subset reader, no new deps, matching the
`soma_lfe_reader` precedent (`apps/soma_lfe/src/soma_lfe_reader.erl`). It
supports `#` comments, blank lines, one optional `[llm]` table header, and
`key = value` lines where the value is a double-quoted string, a bare integer,
or `true`/`false`. Only keys under `[llm]` are read. Lines outside any table,
or under a table other than `[llm]`, are ignored for this slice.

The map build maps the file's `provider` string to the atom `openai_compat` and
keeps `base_url`/`model` as binaries. `enable_thinking` (bool) and `max_tokens`
(int) are copied only when the file sets them; an absent key is left off the
map, matching how `build_call_opts/2`'s `copy_optional` already treats them.

The API key never comes from the file. `load/1` reads `SOMA_LLM_API_KEY` from
the environment the same way `soma_llm_smoke:api_key_from_env/0` does
(`apps/soma_runtime/src/soma_llm_smoke.erl:42`) and puts it on the map as a
binary. An `api_key` line in the file is dropped during parse, so it can never
reach the built map. When the file selects a provider but `SOMA_LLM_API_KEY` is
unset or empty, `load/1` raises (`error({missing_env, "SOMA_LLM_API_KEY"})`),
matching the smoke helper. Raising means no `model_config` with an empty key can
escape, which is the property the open question fixed.

An absent file, or a file with no `[llm]` table, returns `undefined`. That keeps
the daemon's existing behavior the default: `undefined` flows into
`start_link/1` and the ask path stays on the mock.

`daemon/1` resolves the config path, calls `soma_config:load/1`, and adds the
result to the `start_link/1` map under `model_config`. The existing daemon test
asserts on `{ok, Resolved}`, so `daemon/1` keeps its `{ok, Path}` return — the
arity does not change.

That leaves the question of how a test observes the value `daemon/1` threaded
into `start_link/1`, since `start_link/1` returns only `{ok, Pid}`. The seam is
that the daemon's resolve-and-load step is itself `soma_config:load/1` on the
resolved path. A test boots the daemon with a `config_path` override, then calls
`soma_config:load/1` on the same override; the two land on the same value by
construction, so the test pins what the daemon resolved. That the threaded value
actually reaches the actor is then proved end to end: a `soma ask` against the
daemon drives the configured provider (criteria 8, 9, 10). The pass-through is
proved by the resolve-and-load seam plus the behavior the threaded value
produces, not by reaching into the listener's state.

## Acceptance criteria → tests

### Criterion 1 — `[llm]` table builds the base provider map
- Call chain: none (pure module call). Test calls `soma_config:load/1` with a
  `config_path` pointing at a temp TOML file holding an `[llm]` table with
  `provider`, `base_url`, `model`.
- Test entry: `soma_config:load/1`.
- Test: `test_load_llm_table_builds_provider_map` in
  `apps/soma_actor/test/soma_config_tests.erl`

### Criterion 2 — optional `enable_thinking` / `max_tokens` carry through, absent keys left off
- Call chain: none (pure module call). One temp file sets both keys, a second
  sets neither; the test reads both back through `load/1`.
- Test entry: `soma_config:load/1`.
- Test: `test_load_carries_optional_keys_and_omits_absent` in
  `apps/soma_actor/test/soma_config_tests.erl`

### Criterion 3 — `api_key` comes from `SOMA_LLM_API_KEY`
- Call chain: none (pure module call). Test sets `SOMA_LLM_API_KEY`, calls
  `load/1` on a provider file, asserts `api_key => <<the env value>>`.
- Test entry: `soma_config:load/1`.
- Test: `test_load_reads_api_key_from_env` in
  `apps/soma_actor/test/soma_config_tests.erl`

### Criterion 4 — `api_key` line in the file is never forwarded
- Call chain: none (pure module call). Temp file carries an `api_key = "..."`
  line with a sentinel; `SOMA_LLM_API_KEY` is set to a different value; the
  test asserts the built map's `api_key` is the env value and the file sentinel
  appears nowhere in the map.
- Test entry: `soma_config:load/1`.
- Test: `test_load_drops_api_key_from_file` in
  `apps/soma_actor/test/soma_config_tests.erl`

### Criterion 5 — provider config with no key fails loudly, no empty-key map escapes
- Call chain: none (pure module call). With `SOMA_LLM_API_KEY` unset and again
  with it set to `""`, the test calls `load/1` on a provider file and asserts it
  raises `{missing_env, _}` (no `{ok, Map}` with an empty `api_key`).
- Test entry: `soma_config:load/1`.
- Test: `test_load_no_api_key_raises` in
  `apps/soma_actor/test/soma_config_tests.erl`

### Criterion 6 — absent file or `[llm]`-less file returns `undefined`
- Call chain: none (pure module call). One call points `config_path` at a
  nonexistent file, one at a temp file with comments but no `[llm]` table; both
  return `undefined`.
- Test entry: `soma_config:load/1`.
- Test: `test_load_absent_or_no_llm_table_is_undefined` in
  `apps/soma_actor/test/soma_config_tests.erl`

### Criterion 7 — daemon resolves config, loads it, threads it into `start_link/1`; `undefined` with no `[llm]`
- Call chain: `soma_cli:daemon/1` → resolve config path → `soma_config:load/1`
  → `soma_cli_server:start_link/1`.
- Test entry: `soma_cli:daemon/1` (booted with a `config_path` override at a
  temp file). The test reads back the resolved value by calling
  `soma_config:load/1` on the same override and asserts the daemon passed that
  value: with an `[llm]`-less / absent file the resolved value is `undefined`,
  so the listener the daemon booted drives the mock for a `soma ask` (proved in
  criterion 8). The start_link layer is not bypassed; the daemon boots a real
  listener.
- Test: `test_daemon_threads_loaded_model_config` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 8 — absent / `[llm]`-less config, `soma ask` runs the mock byte-for-byte
- Call chain: `soma_cli:daemon/1` (no/`[llm]`-less config) → `soma_cli_server`
  listener with `model_config => undefined` → client `soma_cli:ask/1` over the
  socket → `handle_ask/2` → `mock_llm_opts(undefined)` → `soma_actor:ask/3` →
  mock LLM path.
- Test entry: `soma_cli:ask/1` against the daemon (a real socket — this is the
  one case that legitimately opens a `{local, _}` socket, the same as the
  existing CLI.2 ask test). The mock directive comes from a mock `model_config`
  passed to `start_link/1`, matching `test_ask_prints_reply_result_exit_zero`.
- Test: `test_ask_no_config_runs_mock` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 9 — real-provider config: daemon passes that map, actor carries it
- Call chain: `soma_cli:daemon/1` (config_path at a real-provider TOML,
  `SOMA_LLM_API_KEY` set) → `soma_config:load/1` → `soma_cli_server:start_link/1`
  with that map → `handle_ask/2` starts a `soma_actor` whose `model_config` is
  that map.
- Test entry: `soma_cli:daemon/1`. The test asserts `soma_config:load/1` on the
  daemon's resolved override returns the real-provider map, and that the actor
  the ask path starts carries the same map (read via the actor's task path /
  the resulting provider request, no live socket to a model).
- Test: `test_daemon_real_provider_config_reaches_actor` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 10 — end-to-end with the fixed-response seam, request carries the user's intent
- Call chain: `soma_cli:daemon/1` (real-provider config carrying a fixed
  `response`) → listener → `soma_cli:ask/1` intent → `handle_ask/2` →
  `soma_actor:ask/3` → `build_call_opts/2` (openai_compat) → `soma_llm_openai`
  parses the fixed `response`, opens no socket.
- Test entry: `soma_cli:daemon/1` + `soma_cli:ask/1` for the rendered answer;
  the provider-request-carries-intent half enters at `build_call_opts/2` to read
  the user message, since the fixed-response seam means no request is sent on the
  wire to observe. No socket to a model is opened.
- Test: `test_ask_real_provider_returns_fixed_response_answer` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 11 — `SOMA_LLM_API_KEY` in no event payload and no rendered reply (regression guard)
- Call chain: `soma_cli:daemon/1` (real-provider config, `SOMA_LLM_API_KEY` a
  sentinel) → ask through the fixed-response seam → events under the task's
  correlation id + the rendered `(result ...)` reply.
- Test entry: `soma_cli:ask/1` against the daemon for the rendered reply, then
  `soma_event_store:by_correlation/2` for the events. The test asserts the
  sentinel appears in no event field and nowhere in the rendered reply. This
  mirrors the existing actor-level guards in
  `soma_actor_real_provider_SUITE.erl` but runs through the daemon's config path.
- Test: `test_real_provider_api_key_leaks_nowhere` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

## Risks & trade-offs

The hand-rolled TOML reader covers only the keys this slice names. A real TOML
file with arrays, nested tables, or multiline strings under `[llm]` will not
parse cleanly. That is the deliberate cost of zero new deps; the same narrow
shape the `soma_lfe` reader took. If a later slice needs richer config, the
reader grows or a dep is reconsidered then, not now.

`soma_config_tests.erl` legitimately references `base_url` and `api_key` as
literals. The no-network marker scans (`soma_cli_2_marker_tests` and siblings)
work off explicit include lists, so this file must not be added to any of them —
the test must stay off those scan lists, per the issue's constraint. The risk is
a future scan switching to a glob and flagging it; the include-list precedent
keeps that from happening silently.

The `soma_cli_server_SUITE` ask tests in criterion 8 open a real `{local, _}`
socket, which is allowed (the existing CLI.2 ask test does the same). The
real-provider cases (9, 10, 11) deliberately use the fixed-response seam so they
open no socket to a model and add no network to the gate. The seam is the only
thing keeping these on the gate; if a test reached `soma_llm_openai` without a
fixed `response`, it would try to dial the configured `base_url`. Every
real-provider test here sets `response`, and the `base_url` literals are
scheme-less so no test names a dialable address.

# node B.1: real OpenAI-compatible LLM provider behind soma_llm_call seam

## Current state

`soma_llm_call:perform_call/1` only knows the mock. It takes an `llm` map with a
`directive` field (`success` / `proposal` / `slow` / `hang` / `crash`) and either
returns the configured output or blocks or crashes. There is no real provider —
nothing in the codebase opens a socket to an LLM, and nothing turns a model's
text into a proposal.

`soma_proposal:normalize/1` already accepts a `reply` proposal: a map
`#{kind => reply, text => Text}` where `Text` is a binary. That is the shape a
real provider has to produce so the rest of the decision loop keeps working
unchanged.

`apps/soma_runtime/src/soma_runtime.app.src` lists only `kernel`, `stdlib`,
`soma_event_store`, `soma_tools` under `applications`. An HTTP call through
`httpc` needs `inets` and `ssl` started, so neither is declared today.

The CLI adapter in `soma_tool_call.erl` sets the precedent for "bounded error":
it never returns a raw provider blob, it returns named tagged tuples like
`{error, {cli_exit_status, N, Excerpt}}` and `{error, {cli_executable_not_found,
Executable}}`. The provider's parse failures follow that same shape.

## Approach

Add one module, `soma_llm_openai`, in `apps/soma_runtime/src/`. It has two pure
functions and one impure one. The two pure functions are what the gate tests:

- `build_request/1` takes a config-plus-opts map and returns the pieces of an
  HTTP POST: the url, the headers, and the JSON-encoded body. It does not send
  anything. The url is `{base_url}/chat/completions`. The headers carry
  `Authorization: Bearer <api_key>`. The body is `json:encode/1` of a map that
  always has `model` and `messages`, and has `max_tokens` and `enable_thinking`
  only when the caller passed those opts.
- `parse_response/1` takes a raw HTTP response (status plus body) and returns
  either `{ok, #{kind => reply, text => Content}}` or a bounded
  `{error, Reason}`. On a 200 with a well-formed body it pulls
  `choices[0].message.content` as a binary and wraps it as a `reply` proposal.
  On a non-200, on a body that does not decode, or on a body missing the
  expected fields, it returns a named error and does not crash.

The impure function (call it `call/2`) is the one that runs `httpc:request/4`.
It builds the request, sends it, and hands the response to `parse_response/1`.
The gate never reaches this function — it is only exercised by the opt-in smoke
test that talks to a real key.

JSON stays on OTP's built-in `json` module (`json:encode/1`, `json:decode/1`),
no new dependency. This matches the release-self-contained rule in CLAUDE.md and
the issue's first open question.

`perform_call/1` grows one new clause. When the `llm` opts map carries
`provider => openai_compat`, it routes to `soma_llm_openai`. Every existing
`directive`-keyed clause stays exactly as it is, so the mock is still the default
and the directive callers see no change. The new clause is matched on the
`provider` key, which the mock directives never carry, so the two paths do not
collide.

`inets` and `ssl` get added to the `applications` list in `soma_runtime.app.src`
so a real release starts them. The gate does not start them because the gate
never takes the real path.

The smoke test lives outside the gate. It is a standalone escript (or a module
function not named `*_test` and not in a `*_SUITE`), so neither `rebar3 eunit`
nor `rebar3 ct` picks it up. It reads a real key from an env var, calls a SophNet
model, and prints the `reply` proposal it gets back.

`docs/usage.md` gains a section on configuring a real provider — key from an env
var, base_url and model from config — and how to run the smoke test.

## Acceptance criteria → tests

All pure-function tests go in a new EUnit module
`apps/soma_runtime/test/soma_llm_openai_tests.erl`, following the repo
convention of a `test_<name>/0` helper called by a thin `<name>_test/0` wrapper.
The two `perform_call/1` routing tests go in the existing
`apps/soma_runtime/test/soma_llm_call_tests.erl`.

### Criterion 1 — request url is base_url + /chat/completions
- Call chain: none (direct function call on a pure function)
- Test entry: `soma_llm_openai:build_request/1`, called with a fixed dummy config
- Test: `test_build_request_url` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 2 — Authorization header is Bearer + key
- Call chain: none (direct function call on a pure function)
- Test entry: `soma_llm_openai:build_request/1`, asserting the header list
- Test: `test_build_request_auth_header` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 3 — body is a JSON object with model and messages
- Call chain: none (direct function call on a pure function)
- Test entry: `build_request/1`, then `json:decode/1` of the returned body to
  assert `model` and `messages` are present
- Test: `test_build_request_body_has_model_and_messages` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 4 — body includes enable_thinking and max_tokens when supplied
- Call chain: none (direct function call on a pure function)
- Test entry: `build_request/1` with both opts set, decode the body, assert both keys present
- Test: `test_build_request_body_includes_optional_opts` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 5 — body omits enable_thinking and max_tokens when absent
- Call chain: none (direct function call on a pure function)
- Test entry: `build_request/1` with neither opt, decode the body, assert both keys absent
- Test: `test_build_request_body_omits_optional_opts` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 6 — parse_response maps a success body to a reply proposal
- Call chain: none (direct function call on a pure function)
- Test entry: `soma_llm_openai:parse_response/1`, fed a fixed sample 200 body
  with `choices[0].message.content`
- Test: `test_parse_response_success_to_reply` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 7 — parse_response returns a bounded error for bad input
- Call chain: none (direct function call on a pure function)
- Test entry: `parse_response/1`, fed a non-200 status, an error body, and a
  malformed body in three asserts, each expecting `{error, Reason}` with a named
  atom or small tagged tuple and no crash
- Test: `test_parse_response_bounded_errors` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 8 — perform_call with a directive map is unchanged
- Call chain: none (direct function call on the seam)
- Test entry: `soma_llm_call:perform_call/1` with a `#{directive => success, output => _}` map
- Test: `test_perform_call_directive_unchanged` in `apps/soma_runtime/test/soma_llm_call_tests.erl`

### Criterion 9 — perform_call with a provider map routes to soma_llm_openai
- Call chain: `soma_llm_call:perform_call/1` → `soma_llm_openai` (its parse path)
- Test entry: `perform_call/1` with a `#{provider => openai_compat, ...}` map. The
  test enters at the seam, not at `soma_llm_openai` directly, so it proves the
  routing clause exists. It must not open a socket — see the note below on how.
- Test: `test_perform_call_routes_to_openai` in `apps/soma_runtime/test/soma_llm_call_tests.erl`

### Criterion 10 — the reply proposal passes soma_proposal:normalize/1
- Call chain: `soma_llm_openai:parse_response/1` → `soma_proposal:normalize/1`
- Test entry: `parse_response/1` on a sample success body, then feed the inner
  proposal map into `soma_proposal:normalize/1` and assert `{ok, _}`
- Test: `test_reply_proposal_normalizes` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 11 — inets and ssl are in the app's applications list
- Call chain: none (direct source-file read)
- Test entry: read `apps/soma_runtime/src/soma_runtime.app.src`, parse the
  `applications` list, assert both atoms are members
- Test: `test_app_src_lists_inets_and_ssl` in `apps/soma_runtime/test/soma_llm_openai_tests.erl`

### Criterion 12 — opt-in smoke test calls a real SophNet model and prints the proposal
- Call chain: none (manual, off the gate)
- Test entry: not a gate test. A standalone escript or a module function not
  named `*_test`, run by hand with a real key. The reason it is off the gate:
  it opens a real socket and needs a secret, which the gate must never do.
- Test: a `run/0` (or escript `main/1`) entry; it is verified by being run
  manually, not asserted by the gate

### Criterion 13 — usage.md documents the real provider and the smoke test
- Call chain: none (direct source-file read — documentation)
- Test entry: no automated test; the criterion is a doc edit reviewed by reading
  `docs/usage.md`
- Test: none (documentation criterion)

### Criterion 14 — the gate is green and opens no socket
- Call chain: none (whole-suite property)
- Test entry: `rebar3 eunit && rebar3 ct`. Every provider test above is pure —
  `build_request/1` and `parse_response/1` touch no network, and the
  `perform_call/1` provider-routing test feeds the routing clause input that
  resolves without a socket (see note). No new suite starts `inets` or `ssl`.
- Test: the full gate run, plus a Dialyzer run reported per the issue's out-of-scope note

## Note on testing criterion 9 without a socket

Criterion 9 says `perform_call/1` with a `provider` map "calls `soma_llm_openai`",
and criterion 14 says the gate opens no socket. These pull against each other if
the only entry into `soma_llm_openai` is the function that runs `httpc`. The
design keeps the impure `httpc` call in its own function and routes
`perform_call/1` to a `soma_llm_openai` entry that does the request-build and
response-parse around it. The routing test proves the new clause hands off to
`soma_llm_openai` without the test driving the network call — for example by
giving the provider opts a path that exercises build-then-parse over a supplied
fixed response rather than a live request. The exact split is the Dev's call; the
constraint is that the gate test for criterion 9 must not open a socket, so the
routing proof cannot run the live `httpc` path.

## Risks & trade-offs

- The routing test for criterion 9 cannot prove the full live round trip without
  opening a socket, which the gate forbids. So the gate proves the routing clause
  exists and the pure pieces are correct, and the live round trip is proven only
  by the manual smoke test. That is a real gap — a wiring mistake in the impure
  `httpc` glue that the pure functions do not cover would pass the gate and only
  surface when someone runs the smoke test. The issue accepts this by putting the
  real path behind an opt-in test on purpose.
- `json:decode/1` on an untrusted provider body can throw on malformed input.
  `parse_response/1` has to catch that and turn it into a bounded `{error, _}`,
  not let it escape. Criterion 7 covers the malformed-body case directly.
- Adding `inets` and `ssl` to the app's `applications` means a release now starts
  two more OTP apps at boot even when nobody uses the real provider. That is the
  cost of declaring the dependency honestly. The gate stays offline because no
  test starts them.
- The model and base_url shape is fixed to the validated SophNet contract. Any
  OpenAI-compatible provider that differs in body or response shape is out of
  scope here and would need a follow-up. This slice does not build a
  multi-provider abstraction.

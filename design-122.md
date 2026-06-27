# CLI.2: `soma ask` — agent command (intent → LLM → proposal → result, mock on gate)

## Current state

`soma run` works end to end. A client ships a `(run (step …) …)` s-expr,
`soma_cli_server` compiles it with `soma_lfe:compile/2`, owns a `soma_run`
directly, and renders the terminal outcome as `(result …)`. That whole path lives
in `apps/soma_runtime/src/soma_cli_server.erl` and `soma_cli.erl`, with tests in
`apps/soma_runtime/test/`.

There is no agent command. Three gaps:

- `soma_lfe` has no `(ask …)` form. `soma_lfe:dispatch/1` routes `(msg …)`,
  `(reply …)`, `(run-steps …)`, and falls through to the run path for everything
  else. An `(ask …)` form today lands on `parse_run` and comes back as an
  `invalid_top_level_form` error, not an ask command.
- `soma_cli_server:handle_lisp_request/2` only matches `{ok, #{run := …}}` and
  owns a `soma_run`. It never touches `soma_actor`, so it can't run the decision
  loop (intent → LLM → proposal → policy → result).
- `soma_cli` has `run/1` and `daemon/1` but no `ask/1`.

One more fact shapes the whole design. `soma_runtime` does not depend on
`soma_actor` — the dependency runs the other way (`soma_actor`'s app file lists
`soma_runtime`), and the project's one-way rule says the runtime never imports the
actor. But the ask path *needs* the actor: it's the only thing that runs the
decision loop. So the CLI server, as it sits in `soma_runtime` today, cannot call
`soma_actor:ask/3` without inverting the dependency.

## Approach

### Move the CLI up into `soma_actor`

Relocate `soma_cli.erl`, `soma_cli_server.erl`, and their test files from
`apps/soma_runtime/` into `apps/soma_actor/`. The module names stay the same. The
run path doesn't change — `soma_actor` already depends on `soma_runtime`, so the
server keeps calling `soma_run_sup:start_run/1` exactly as before. The move is
what lets the same server also call `soma_actor:ask/3` for the ask path without
breaking the one-way rule.

This is the honest place for the code. The CLI server is the one component that
has to span both the run path and the agent path, and `soma_actor` is the only app
that can see both. Leaving the server in `soma_runtime` and reaching the actor
through a registered name or an injected pid would dodge the compile-time
dependency but keep the real one — the server would still only work when an actor
is running. The move makes the dependency visible instead of hidden.

The cost is a real one: a git move of three source files and their tests, plus
fixing the two test-contract docs and any marker scans that name the old paths.
It also means `soma_runtime` loses its CLI modules, so anything that referenced
them by app (nothing does today — the daemon entry resolves at runtime) keeps
working. The relay gate runs the whole umbrella, so a missed reference fails the
build, not silently.

### The `(ask …)` form and its parsed shape

`soma_lfe:dispatch/1` gets one new clause: an `(ask …)` head routes to
`soma_lfe_parser:parse_ask/1`. The parsed shape mirrors the run path's
`#{run => #{steps => …}}`:

```
#{ask => #{intent => <<"…">>,
           tool_policy => #{allowed_tools => [echo, file_read]},
           budget => #{max_llm_calls => 3, max_steps => 5}}}
```

`intent` is required — a `(intent "…")` sub-form holding a string. `(allow t1 t2
…)` and the two budget sub-forms are optional. `(allow …)` collects bare tool
symbols into `allowed_tools`. `(budget-llm N)` and `(budget-steps N)` set the two
budget caps. An `(ask …)` with no `(intent …)` is a parse error carrying a
diagnostic, not a malformed ok map — same discipline `parse_msg` uses for its
required fields.

The allow list and budget nest inside the `ask` sub-map, the layout the issue's
open question proposed. That keeps the parsed command self-contained: the server
reads one map and builds one envelope from it.

### The server's ask path

`handle_lisp_request/2` gets a second match clause for `{ok, #{ask := Ask}}`. It
builds an actor envelope from the ask map and drives the decision loop:

- Start an actor under `soma_actor_sup` with the daemon's `model_config` and the
  ask's `tool_policy` + `budget`. The mock-on-gate `model_config` is a directive
  map (no real provider), so `soma_actor:build_call_opts/2` returns the envelope's
  `llm` map unchanged and no socket opens.
- The envelope carries `type`, `payload`, and an `llm` directive map built from
  the `model_config`. The intent rides in the payload. `soma_actor:ask/3` runs the
  call, normalizes the proposal, runs the policy gate, and returns a terminal
  answer.
- Shape the actor's return into a result map for `soma_lisp:render/1`. A `reply`
  proposal comes back as `{ok, #{kind => reply, text => Text}}` → `#{status =>
  completed, outputs => …, correlation_id => …}` with the reply text under
  `outputs`. A `reject` comes back as `{error, {rejected, Reason}}` → `#{status =>
  rejected, error => Reason}`. A budget-0 refusal comes back as `{error,
  {budget_exceeded, max_llm_calls}}` → a non-`completed` status whose `error`
  carries the tuple.

The reply text appears under `outputs`, the existing completed-result sub-form, so
no new renderer form is needed — answering the issue's second open question. The
`reject` reason lands under `error`, the sub-form the renderer already emits for
non-completed results.

The `model_config` is new config on the server. `soma_cli_server:start_link/1`
grows an optional `model_config` field (`#{socket := Path, model_config => …}`);
absent it, the ask path has no mock to drive and the run path is unchanged. The
daemon (`soma_cli:daemon/1`) is where the real provider's `model_config` would be
set; on the gate it's the mock directive.

### `soma_cli:ask/1`

A new client entry mirroring `run/1`. It takes the intent text, wraps it in an
`(ask (intent "…"))` s-expr, connects to the socket, frames and sends, reads the
framed `(result …)`, prints it, and returns the same exit code `run/1` uses (`0`
on `(status completed)`). The client builds the `(ask …)` source from the intent
string; the daemon is still the only parser.

### Mock on the gate

The gate uses mock directives only. The server's test config is a `model_config`
that drives the mock to a `reply` or a `reject` proposal. No real provider, no
network — the same bar CLI.1b held. A marker scan over the new test sources keeps
it that way.

## Acceptance criteria → tests

### Criterion 1 — `(ask (intent "…"))` parses to `#{ask => #{intent => …}}`
- Call chain: none (pure compile). `soma_lfe:compile/2` → `dispatch/1` →
  `soma_lfe_parser:parse_ask/1`.
- Test entry: `soma_lfe:compile/2`, the public boundary.
- Test: `test_ask_intent_parses_to_ask_map` in
  `apps/soma_lfe/test/soma_lfe_ask_tests.erl`

### Criterion 2 — `(ask …)` with no `(intent …)` is a parse error
- Call chain: none (pure compile). Same chain as criterion 1.
- Test entry: `soma_lfe:compile/2`.
- Test: `test_ask_without_intent_returns_error` in
  `apps/soma_lfe/test/soma_lfe_ask_tests.erl`

### Criterion 3 — `(ask …)` with `(allow …)` and budget sub-forms parses them
- Call chain: none (pure compile). Same chain as criterion 1.
- Test entry: `soma_lfe:compile/2`.
- Test: `test_ask_allow_and_budget_parse` in
  `apps/soma_lfe/test/soma_lfe_ask_tests.erl`

### Criterion 4 — a `reply`-yielding ask request returns a completed `(result …)` carrying the reply text
- Call chain: `gen_tcp` client → accept loop → `handle/1` →
  `handle_lisp_request/2` → `soma_lfe:compile/2` → `soma_actor_sup:start_actor` →
  `soma_actor:ask/3` → mock `soma_llm_call` → `soma_proposal:normalize/1` →
  `soma_policy:check/2` → `soma_lisp:render/1` → framed reply.
- Test entry: the `gen_tcp` client (no layer bypassed — the test drives the real
  socket).
- Test: `test_ask_reply_returns_completed_result_with_text` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 5 — a `reject`-yielding ask request returns a rejected `(result …)` carrying the reason
- Call chain: same as criterion 4, but the mock yields a `reject` proposal, so
  `soma_policy:check/2`'s verdict path ends at `{error, {rejected, Reason}}`.
- Test entry: the `gen_tcp` client.
- Test: `test_ask_reject_returns_rejected_result_with_reason` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 6 — `(budget-llm 0)` drives a non-completed result carrying `{budget_exceeded, max_llm_calls}`
- Call chain: `gen_tcp` client → … → `soma_actor:ask/3` →
  `maybe_start_llm_call/4` → `llm_budget_available/2` (false) → `fail_task/3`. No
  LLM call starts.
- Test entry: the `gen_tcp` client.
- Test: `test_ask_budget_llm_zero_returns_budget_exceeded` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`

### Criterion 7 — `soma_cli:ask/1` sends an intent, prints the `(result …)`, exits 0
- Call chain: `soma_cli:ask/1` → `gen_tcp:connect` → real `soma_cli_server` on a
  temp socket → the criterion-4 server chain → `soma_cli:ask/1` prints and returns
  the exit code.
- Test entry: `soma_cli:ask/1`, the client boundary.
- Test: `test_ask_prints_reply_result_exit_zero` in
  `apps/soma_actor/test/soma_cli_SUITE.erl`

### Criterion 8 — `docs/cli.md` documents the finalized `soma ask` flow
- Call chain: none (docs deliverable).
- Test entry: off chain — prose, no test function. The CLI.1b precedent treats the
  docs prose as the deliverable.
- Test: the prose in `docs/cli.md` (the `(ask …)` request, the `(result …)` reply,
  mock-on-gate vs real-provider-by-config).

### Criterion 9 — `docs/contracts/cli-2-test-contract.md` names a suite/module and case per criterion
- Call chain: none (the doc pins itself through a source scan).
- Test entry: `soma_cli_2_contract_tests`, which reads the doc file and asserts it
  names every CLI.2 suite/module and each case name above.
- Test: `test_doc_names_cli_2_suites_and_cases` in
  `apps/soma_actor/test/soma_cli_2_contract_tests.erl`

### Criterion 10 — `rebar3 eunit && rebar3 ct` green, no real LLM, no non-local socket
- Call chain: none (a source scan over the new CLI.2 test files for real-provider
  / non-local-socket markers, plus the gate run itself).
- Test entry: `soma_cli_2_marker_tests`, which scans the new test sources. The
  "gate is green / dialyzer reported" half is verified by running the gate and
  recording the result in the PR, not by a test function.
- Test: `test_cli_2_sources_have_no_real_provider_or_socket_marker` in
  `apps/soma_actor/test/soma_cli_2_marker_tests.erl`

## Risks & trade-offs

- **The file move is the big one.** Moving `soma_cli` / `soma_cli_server` and
  their tests from `soma_runtime` to `soma_actor` touches the CLI.1b contract doc,
  the CLI.1 / CLI.1.5 contract docs, and the marker/contract scans that name the
  old `apps/soma_runtime/test/` paths. Each of those has to be updated in the same
  PR or the gate goes red. The move is mechanical, but it's wide.

- **The alternative — keep the server in `soma_runtime` and reach the actor
  through a registered name or injected pid — was rejected.** It would compile
  without a new app dependency, but the runtime dependency on the actor would still
  be real at runtime: the ask path only works when an actor is up. Hiding a real
  dependency behind a name lookup is worse than declaring it.

- **The mock `model_config` shape is a server config field, not a wire field.**
  The client never sends a model. That's correct for the security model (the key
  and provider live at the daemon), but it means the gate's `reply` / `reject` /
  budget cases are driven by server-side config the test sets, not by the request.
  The test has to start the server with the right `model_config` for each case.

- **`reply` text under `outputs` reuses an existing sub-form.** It keeps the
  renderer unchanged, but it means a reader can't tell a `soma run` output from a
  `soma ask` reply by the result shape alone — both are `(outputs …)`. The
  `task-id` / `correlation-id` are still there; distinguishing the two is left to
  the caller's context, which is fine for now since `soma ask` is reply-only.

- **Scope held to a `reply`.** The policy gate, `--allow`, and `--budget-steps`
  are wired through to the actor but inert for a `reply` — the real provider yields
  only `reply` proposals today. The one budget effect a reply can show is the
  `(budget-llm 0)` up-front refusal (criterion 6). When `run_steps` proposals land
  later, these flags become load-bearing; this slice does not test that path.

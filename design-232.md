# [cc] AS.4: expose optional explore mode through local config and CLI

## Current state

AS.3 already owns bounded exploration inside `soma_actor`. A model config with
`explore => true` makes provider text enter the round-reply parser. Reader
actions start ordinary owned `soma_run` children. Their outputs become bounded
observations for the next model request. A terminal reply enters the existing
proposal path. That path owns normalization, policy checks, budgets, execution,
and task results. The actor reads `max_explore_rounds` and
`max_observation_bytes` from its `budget` option. It emits
`explore.round.started` and `explore.round.completed` on the task's correlation
trail.

The actor also has the hermetic seams this slice needs. `response_sequence`
selects one fixed provider response for each round. A response may be a function
that records the built request before returning a fixed provider body. These
keys exist only in direct Erlang maps. `soma_config` does not load them from a
file.

`soma_config:load/1` cannot enable explore mode today. Its `[llm]` allowlist
carries only `enable_thinking`, `max_tokens`, and `plan`. `parse_value/1`
recognizes quoted strings and booleans. Every other value is passed to
`list_to_integer/1`. An unparseable bare value raises before
`build_model_config/1` can name the bad key. `soma_cli:daemon/1` catches that
error and refuses to start the listener.

`soma_cli` passes the loaded model config unchanged to `soma_cli_server`. The
ask handler puts that map in the actor's `model_config`. It copies only an
ask-form `(budget ...)` map into the actor's `budget`. Values placed at
`model_config.max_explore_rounds` or
`model_config.max_observation_bytes` never reach the budget fields AS.3
enforces.

The synchronous run path watches its socket with `{active, once}`. The ask path
does not. `handle_ask_with_model/4` calls `soma_actor:ask/3` in the connection
handler, so that process cannot receive `tcp_closed` until the ask returns. The
actor already monitors a parked `ask/3` caller. It cancels the caller's active
LLM worker or run when that caller dies. The CLI server does not yet connect
client-socket death to that actor mechanism.

Trace support is already present. `soma_actor` appends both round events to the
correlation trail. `soma_trace:render_lisp/2` renders that trail in event order.
`soma_cli:trace/1` exposes the renderer over the existing local socket form.

Config-registered CLI tools also have the required mechanics. A `(tool ...)`
file passes through `soma_tool_config` and
`soma_tool_manifest:normalize/1`. It then lands in the descriptor registry.
Whole-argument placeholders such as `"{input}"` are validated against
`params`. `soma_run` replaces them after step-input resolution and before it
starts `soma_tool_call`. The repository has no fine-grained docmod example
files that users can register.

## Approach

Keep the AS.3 actor loop and the runtime unchanged. This slice should not add an
explore loop to the CLI server. It should validate local settings, translate the
two config limits into the actor's existing budget map, and preserve a
synchronous ask's ownership across the socket boundary.

Make parsing of the three new `[llm]` keys total and key-aware. The accepted
shapes are fixed:

- `explore` accepts a boolean.
- `max_explore_rounds` accepts a positive integer.
- `max_observation_bytes` accepts a positive integer.

Do not call `list_to_integer/1` blindly for these keys. Preserve an unparseable
token as a private invalid marker so validation can report the key without
raising. Quoted values, booleans in integer fields, zero, and negative integers
are invalid too.

Use one allowlisted validator for this three-key group. A valid present key is
copied into the returned model config under its existing atom name. An absent
key is omitted. This keeps a file with no explore settings on the current path.
An explicit `explore = false` remains valid and keeps exploration off. Existing
config suites remain the compatibility proof for absent settings. This issue
does not add another absence test.

On an invalid value, emit one bounded logger warning carrying
`{invalid_llm_setting, Key, Expected}`. `Key` is one of the three fixed config
key atoms. `Expected` is `boolean` or `positive_integer`. Do not include the raw
config value in the warning. If any key in the group is invalid, omit all three
keys from the model config. A bad limit must not silently start exploration with
a different limit. Existing fatal errors for missing provider fields and
`SOMA_LLM_API_KEY` stay unchanged.

In `soma_cli_server`, derive a config explore-budget map only when the model
config carries `explore => true`. Copy the two positive limits from the model
config into that map. Merge it with the ask form's existing budget map. The ask
form's current keys are `max_llm_calls` and `max_steps`, so their behavior stays
unchanged. Put `budget` in the actor options only when the merged map is
non-empty. A config with no explore keys therefore creates the same actor
options it creates today. `soma_actor` remains the only owner of round counting
and observation truncation.

Make synchronous asks disconnect-aware without changing the wire form. Pass the
accepted socket into the ask handler. Start a short-lived monitored process
whose only job is to call `soma_actor:ask/3` and send its tagged result to the
connection handler. The connection handler keeps ownership of the socket. It
arms `{active, once}` and waits for the tagged ask result or
`{tcp_closed, Socket}`.

When the result arrives, demonitor the short-lived caller with `[flush]` and
feed the result through the existing result-to-Lisp mapping. When the socket
closes first, terminate the short-lived caller and return `noreply`. The actor's
existing waiter monitor then receives that caller's `DOWN` signal. It cancels
the active `soma_llm_call` or sends `cancel` to the active explore run. The
unchanged run owns tool-worker and external-process teardown. Tags on helper
messages keep a stale result or `DOWN` signal from satisfying another wait.

Use the existing `response_sequence` seam for gate coverage. Each integration
test first loads a real provider map from a temporary config file. It then adds
only the fixed response sequence in the test process before starting the local
listener. The first response requests a reader step. A later response either
terminates the task or proves round exhaustion. A responder records the second
request so the test can inspect the actual bounded observation. No response
seam becomes a config key. No gate test opens a provider socket.

Add three copyable files under `examples/docmod-tools/`:

- `docmod_help.lisp` declares a reader, idempotent CLI tool with argv `help` and
  `"{topic}"`. It declares one required string `topic` parameter.
- `docmod_read.lisp` declares a reader, idempotent CLI tool with argv `read` and
  `"{input}"`. It declares one required string `input` parameter.
- `docmod_edit.lisp` declares a state, non-idempotent CLI tool with argv `edit`,
  `"{input}"`, and `"{changes}"`. It declares required string parameters for
  the input document and changes HTML file.

Each file should declare a positive timeout, `adapter cli`, and a model-facing
description. Each executable should be the literal user-replaced path
`/REPLACE/WITH/PATH/TO/docmod`. The normalizer does not require that path to
exist. The manual must tell users to replace it before registration.

Test the examples through production boundaries. One test loads the example
directory with `soma_tool_config:load_dir/1` and resolves all three descriptors.
This proves the Lisp files compile and pass the shared normalizer. A second test
copies `docmod_help.lisp` to a temporary tools directory. It replaces only the
executable path with a suite-created stub before loading it with the same
loader. Starting a one-step run with a `topic` argument must make the stub
report exactly two arguments in order: `help`, then the topic. The placeholder
form must not append a compatibility input argument.

Update `docs/usage.md` in two places. The model section should show all three
explore settings for `soma ask`. It should explain the accepted types, the
positive limits, and fail-closed behavior. The config-tool section should show
the three example manifest paths, the executable replacement, and registration
commands for all three names.

Create `docs/contracts/AS.4-test-contract.md`. It should map each issue
criterion to the one exact proving test below. Add one source-file test for the
manual and a separate source-file test for the contract map. Do not update
README, the roadmap, release smoke material, or `docs/cli.md` in this slice.

## Acceptance criteria → tests

### Criterion 1 — `explore = true` reaches the daemon model config

- Call chain: `soma_config:load/1` → `resolve_path/1` →
  `read_llm_table/1` → `[llm]` value collection →
  `build_model_config/1` → explore-setting validation and carry.
- Test entry: `soma_config:load/1` with one temporary provider config carrying
  `explore = true`.
- Code boundary: `[llm]` parsing and model-config construction in
  `apps/soma_actor/src/soma_config.erl`.
- Responsibility owner: `soma_config` owns the local text-to-model-config
  boundary and the fixed optional-key allowlist.
- Test: `test_load_carries_explore_true` in
  `apps/soma_actor/test/soma_config_tests.erl`.

### Criterion 2 — a socket ask uses both configured explore budgets

- Call chain: `soma_config:load/1` → `soma_cli_server:start_link/1` →
  `soma_cli:ask/1` → local `(ask ...)` frame →
  `handle_ask_with_model` → configured explore-budget extraction →
  `soma_actor_sup:start_actor/1` → explore round checks and bounded
  observation construction.
- Test entry: `soma_cli:ask/1` against a temporary local socket. One config
  fixture carries positive `max_explore_rounds` and
  `max_observation_bytes` values. The listener receives the loaded map plus a
  socket-free response sequence. The test observes a capped reader output and
  exhaustion before the next model call.
- Code boundary: validated optional fields in
  `apps/soma_actor/src/soma_config.erl` and actor-option assembly in
  `apps/soma_actor/src/soma_cli_server.erl`.
- Responsibility owner: the config loader owns value validation. The CLI
  server owns translation from daemon config to actor options. `soma_actor`
  keeps enforcement ownership.
- Test: `test_explore_ask_uses_configured_round_and_observation_budgets` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`.

### Criterion 3 — invalid settings emit diagnostics that name their keys

- Call chain: `soma_config:load/1` → total value parsing →
  explore-setting validation → bounded logger warning → model config with
  the explore group omitted.
- Test entry: `soma_config:load/1` with one temporary `[llm]` table carrying an
  invalid value for each of the three keys. A test logger handler records all
  warnings in this one case.
- Code boundary: explore-setting validation and warning construction in
  `apps/soma_actor/src/soma_config.erl`.
- Responsibility owner: `soma_config` owns diagnostics for rejected local
  settings.
- Test: `test_invalid_explore_settings_emit_keyed_diagnostics` in
  `apps/soma_actor/test/soma_config_tests.erl`.

### Criterion 4 — an unparseable setting boots a reachable non-explore daemon

- Call chain: `soma_cli:daemon/1` → `load_model_config/1` →
  `soma_config:load/1` → invalid explore group omitted → runtime boot →
  `soma_cli_server:start_link/1` → `soma_cli:ping/1`.
- Test entry: `soma_cli:daemon/1` with a complete provider config whose
  `explore` value is an unparseable bare token. The test pings the bound local
  socket and checks that loading the same file produces no explore key.
- Code boundary: total parsing and fail-closed group handling in
  `apps/soma_actor/src/soma_config.erl`. The daemon boot path is exercised but
  should not need a behavior change.
- Responsibility owner: `soma_config` decides that a bad optional explore
  group is nonfatal and disabled.
- Test: `test_unparseable_explore_setting_keeps_daemon_reachable_and_off` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`.

### Criterion 5 — one reader round feeds a terminal socket result

- Call chain: `soma_config:load/1` → `soma_cli_server:start_link/1` →
  `soma_cli:ask/1` → local socket → `soma_actor:ask/3` → fixed provider
  round one → reader admission → owned `soma_run` → bounded observation
  → fixed provider round two → terminal proposal normalization and result
  rendering.
- Test entry: `soma_cli:ask/1` with a model map produced by
  `soma_config:load/1` and augmented only with the existing response-sequence
  test seam. The second responder records its request before returning a
  terminal `(reply ...)` proposal.
- Code boundary: config carry and ask wiring in
  `apps/soma_actor/src/soma_config.erl` and
  `apps/soma_actor/src/soma_cli_server.erl`. The AS.3 actor loop is asserted
  unchanged.
- Responsibility owner: the config and CLI edge enable the mode. `soma_actor`
  remains the owner of the reader round, observation, and terminal proposal.
- Test: `test_config_loaded_explore_ask_returns_terminal_result_with_bounded_observation`
  in `apps/soma_actor/test/soma_cli_server_SUITE.erl`.

### Criterion 6 — `soma trace` shows exploration rounds in event order

- Call chain: completed `soma_cli:ask/1` → correlation id →
  `soma_cli:trace/1` → local `(trace ...)` frame →
  `soma_cli_server:handle_trace/1` → `soma_trace:render_lisp/2` →
  `soma_event_store:by_correlation/2`.
- Test entry: `soma_cli:ask/1` completes a fixed-response explore task. The
  test extracts its correlation id from the printed result and calls
  `soma_cli:trace/1` against the same listener. Entering at the thin clients is
  required because this criterion covers the packaged command path, not only
  the renderer.
- Code boundary: existing trace exposure in
  `apps/soma_actor/src/soma_cli_server.erl` and
  `apps/soma_event_store/src/soma_trace.erl`. No renderer change is expected.
- Responsibility owner: `soma_actor` owns round event order. The CLI trace path
  owns showing that stored order to the user.
- Test: `test_trace_after_explore_ask_returns_rounds_in_event_order` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`.

### Criterion 7 — closing the ask socket cancels the explore task

- Call chain: local `(ask ...)` frame → disconnect-aware CLI handler →
  short-lived `soma_actor:ask/3` caller → actor parks and monitors caller →
  client closes the socket during a reader run → handler terminates caller →
  actor receives caller `DOWN` → actor sends `cancel` to the run → run stops
  its tool worker and reports cancellation → actor records
  `actor.task.cancelled`.
- Test entry: a raw local `gen_tcp` client sends the ask and waits for the reader
  tool's `tool.started` event before closing its socket. Raw socket entry is
  required because `soma_cli:ask/1` waits for a reply and closes only after
  completion.
- Code boundary: synchronous ask waiting and socket ownership in
  `apps/soma_actor/src/soma_cli_server.erl`. Existing caller-death handling in
  `apps/soma_actor/src/soma_actor.erl` and run cancellation are observed but
  not modified.
- Responsibility owner: the CLI server owns the client-to-caller lifetime
  bridge. The actor and run keep ownership of their current children.
- Test: `test_explore_ask_client_disconnect_cancels_actor_task` in
  `apps/soma_actor/test/soma_cli_server_SUITE.erl`.

### Criterion 8 — all three docmod examples normalize with honest metadata

- Call chain: `soma_tool_config:load_dir/1` → example `.lisp` file read →
  `soma_lfe_reader:read_forms/1` → manifest compilation →
  `soma_tool_registry:register_tool/1` →
  `soma_tool_manifest:normalize/1` → descriptor lookup.
- Test entry: `soma_tool_config:load_dir/1` on `examples/docmod-tools/`. This is
  the loader users run at daemon boot. The case resolves all three descriptors
  and checks their effects, idempotence flags, and argv entries.
- Code boundary: `examples/docmod-tools/docmod_help.lisp`,
  `examples/docmod-tools/docmod_read.lisp`, and
  `examples/docmod-tools/docmod_edit.lisp`.
- Responsibility owner: the example manifests own command shape, parameter
  declarations, effects, and idempotence. The existing normalizer is the
  admission authority.
- Test: `test_docmod_example_manifests_normalize_with_expected_metadata` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`.

### Criterion 9 — `docmod_help` sends `help` before the substituted topic

- Call chain: copied example manifest → `soma_tool_config:load_dir/1` →
  descriptor registry → `soma_agent_session:start_run/2` → `soma_run`
  step-input resolution → argv placeholder rendering → `soma_tool_call` →
  stub executable.
- Test entry: `soma_agent_session:start_run/2` after the exact help example is
  loaded with only its executable path replaced by a suite-created stub.
- Code boundary: `examples/docmod-tools/docmod_help.lisp` and its integration
  test in `apps/soma_actor/test/soma_tool_config_SUITE.erl`. Runtime placeholder
  code is asserted unchanged.
- Responsibility owner: the example owns argv order. The existing run and CLI
  adapter own placeholder substitution and process execution.
- Test: `test_docmod_help_stub_receives_help_then_substituted_topic` in
  `apps/soma_actor/test/soma_tool_config_SUITE.erl`.

### Criterion 10 — usage docs cover explore config and docmod registration

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/usage.md` because this criterion is about the
  user-facing configuration and registration instructions.
- Code boundary: `docs/usage.md` and
  `apps/soma_actor/test/soma_as4_contract_doc_tests.erl`.
- Responsibility owner: the user manual owns operator instructions for
  `soma ask` and config-tool registration.
- Test: `test_usage_documents_explore_settings_and_docmod_registration` in
  `apps/soma_actor/test/soma_as4_contract_doc_tests.erl`.

### Criterion 11 — the AS.4 contract maps every criterion

- Call chain: none (direct source-file read).
- Test entry: EUnit reads `docs/contracts/AS.4-test-contract.md` and checks the
  one proving module and case named for each issue criterion.
- Code boundary: `docs/contracts/AS.4-test-contract.md` and
  `apps/soma_actor/test/soma_as4_contract_doc_tests.erl`.
- Responsibility owner: `docs/contracts/` owns the durable mapping from each
  guarantee to its proving test.
- Test: `test_as4_contract_maps_every_criterion_to_proving_case` in
  `apps/soma_actor/test/soma_as4_contract_doc_tests.erl`.

## Risks & trade-offs

- Logger warnings keep `soma_config:load/1`'s return type unchanged and let the
  daemon boot. They are less convenient for an embedding caller than returned
  diagnostics. A structured fixed warning term keeps the behavior observable
  without adding a service API.
- Disabling the whole explore group when one limit is invalid can surprise an
  operator who expected defaults. Running exploration under a limit that was
  rejected is unsafe. The warning and manual must make the choice visible.
- A short-lived ask caller adds one process to each synchronous ask. It reuses
  the actor's existing waiter monitor and keeps socket events in the handler.
  Tagged messages and `demonitor(..., [flush])` are needed to keep completion
  and disconnect races from leaving stale signals.
- The supervised actor created for an ask remains subject to the current actor
  lifecycle after its task is cancelled. This slice cancels the task and its
  active child. Changing per-request actor lifetime is outside #232.
- The fixed response sequence contains functions and request maps, so it must
  remain a direct test seam. Loading it from local config would expose an
  executable config surface and is not part of this issue.
- The docmod example executable is deliberately unusable until the user edits
  it. Validation can prove the manifest shape without a local docmod install,
  but an unedited example fails when invoked. The manual must put replacement
  before registration.
- `soma_config` remains a small TOML subset. Making these three values total
  should not turn it into a general TOML parser or change unrelated provider
  error behavior.

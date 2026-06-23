# [cc] v0.2: publish the v0.2 process-behaviour test contract

## Current state

v0.2 is built and its tests pass. EUnit is 54 tests, Common Test is 61 tests,
both green at the branch HEAD. The pieces shipped one issue at a time: manifest
validation (`soma_tool_manifest:normalize/1`, #15), the descriptor registry
(#16), built-ins registered through manifests (#17), and the one-shot `cli`
adapter (#18–#21) with a packaged sample helper (#22).

What's missing is a single place that states the v0.2 process-behaviour contract
and names the test that proves each line of it. Right now the proofs are spread
across six suites. Someone who wants to check "does v0.2 still kill the external
OS process when a cli run is cancelled?" has to go read the suites to find out.
The roadmap rule is: don't add the next layer until the one below has
failure-behaviour test coverage you can point at. That pointer doesn't exist yet.

The README also stops at v0.1. It says nothing about manifests, the descriptor
registry, or the cli adapter, so a reader has no summary of what v0.2 added.

## Approach

Two artifacts.

1. A new doc, `docs/v0.2-test-contract.md`, holds the contract: it lists each
   v0.2 process-behaviour proof and names the suite and case that proves it. This
   is the v0.2 counterpart to the v0.1 ten-proof contract. It sits next to
   `docs/design.md` and `docs/tool-manifest.md` as a peer.

2. A new v0.2 section in the README summarizes what v0.2 adds — tool manifests,
   the descriptor registry, the one-shot cli adapter (lifecycle teardown, failure
   normalization, argv/env/cwd safety) — states what stays out of scope (later
   roadmap layers, plus the still-open Linux x86_64/arm64 release packaging), and
   links to the contract doc.

The contract doc lives in `docs/` rather than inline in the README because the
proof→test map is a long table that would bury the README's narrative. The README
keeps the summary; the doc keeps the map. Both are reachable from the README's
Docs list, so both are discoverable.

The contract reuses the v0.2 suites as-is. The issue is explicit that this work
maps and publishes, it does not rewrite proven tests. Every proof below already
resolves to a passing case except one half of one proof, called out as a gap and
closed with a single new EUnit case.

### The gap

The issue's second proof has two halves: a manifest missing a required field is
rejected, *and* that tool name does not resolve through the registry. The first
half is proven by `test_normalize_rejects_missing_shared_field`. The second half
is not. No existing test feeds a missing-field manifest into the running registry
through `register_tool/1` and then confirms the name fails to resolve.

`soma_tool_registry:register_tool/1` already does the right thing: it calls
`normalize/1`, and on `{error, _}` it returns the error and leaves the registry
unchanged (`apps/soma_tools/src/soma_tool_registry.erl:117`). So the behaviour is
real, it just has no test naming it. Dev adds one EUnit case in
`soma_tool_registry_tests` that registers a missing-field manifest, asserts
`register_tool/1` returns the rejection, and asserts `resolve_descriptor/1` for
that name returns `{error, not_found}`. That closes the second half against the
running registry, not just the pure `normalize/1` function.

## Acceptance criteria → tests

The first criterion (a documented proof set exists and is verifiable by following
the map) and the last criterion (the README v0.2 section) are satisfied by the two
artifacts above, not by a test. Every other criterion maps to a case below.

### Criterion 2 — missing required field rejected, and the name does not resolve
- Call chain (reject half): test → `soma_tool_manifest:normalize/1`
- Test entry: `soma_tool_manifest:normalize/1` (pure function, no run layer involved)
- Test: `test_normalize_rejects_missing_shared_field` in `apps/soma_tools/test/soma_tool_manifest_tests.erl`
- Call chain (does-not-resolve half): test → `soma_tool_registry:register_tool/1` → `normalize/1` returns `{error, _}` → registry unchanged → `soma_tool_registry:resolve_descriptor/1` → `{error, not_found}`
- Test entry: `soma_tool_registry:register_tool/1` on the running registry gen_server
- Test: **gap — new** `test_register_tool_rejects_missing_field_name_unresolvable` in `apps/soma_tools/test/soma_tool_registry_tests.erl`

### Criterion 3 — built-ins register through manifest validation, echo still runs end-to-end
- Call chain (register-through-manifest half): test → `soma_tool_registry:resolve_descriptor/1` on the seeded registry, compared against `soma_tool_manifest:normalize(Module:manifest())` for each built-in
- Test entry: `soma_tool_registry:resolve_descriptor/1` (the live seeded registry; the seed itself is built by normalizing each built-in manifest)
- Test: `test_registry_seeds_descriptors_from_manifests` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`
- Call chain (echo end-to-end half): test → `soma_agent_session:start_run/2` → `soma_run` step cursor → `soma_tool_call` worker runs `echo` → run reaches `run.completed`
- Test entry: `soma_agent_session:start_run/2` (no layer bypassed)
- Test: `test_multi_step_runs_sequentially_to_completed` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 4 — a cli tool drives a run to completed
- Call chain: test → `soma_agent_session:start_run/2` → `soma_run` → `soma_tool_call` spawns the cli helper through a port → run reaches `run.completed`
- Test entry: `soma_agent_session:start_run/2` (no layer bypassed)
- Test: `test_cli_run_reaches_completed` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 5 — the cli call runs in its own worker, pid distinct from the run
- Call chain: test → `soma_agent_session:start_run/2` → `soma_run` (its pid read back through `run_pid/0`) → `soma_tool_call` worker (its pid carried on the `tool.started` and `tool.succeeded` events)
- Test entry: `soma_agent_session:start_run/2`; the test reads worker and run pids off the event trail rather than poking the processes directly, since the trail is where the run records the boundary
- Test: `test_cli_tool_call_has_distinct_pid` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`

### Criterion 6 — a successful cli call emits the same event trail as an Erlang tool
- Call chain: test → `soma_agent_session:start_run/2` → `soma_run` → `soma_tool_call` → run records `tool.started`, `tool.succeeded`, `step.succeeded`, then `run.completed`
- Test entry: `soma_agent_session:start_run/2`
- Test: `test_cli_step_event_order` in `apps/soma_runtime/test/soma_cli_adapter_SUITE.erl`, asserting `tool.started < tool.succeeded < step.succeeded`; `run.completed` in the same trail is asserted by `test_cli_run_reaches_completed` in the same suite, which runs the same one-step cli run
- Note: no single case asserts all four events in one ordered chain. The two cases together cover the trail (`test_cli_step_event_order` for the first three in order, `test_cli_run_reaches_completed` for `run.completed` in the trail). The contract doc states this split so the map is honest; closing it into one assertion is optional and not required by the criterion.

### Criterion 7 — nonzero exit and a missing/unrunnable executable each reach failed, session stays alive
- Call chain: test → `soma_agent_session:start_run/2` → `soma_run` → `soma_tool_call` opens the port → port-open failure or nonzero exit → worker returns a named `{error, _}` → `soma_run` runs `fail_run` → `run.failed`
- Test entry: `soma_agent_session:start_run/2`
- Tests (nonzero exit): `test_non_zero_exit_carries_status` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`
- Tests (missing executable): `test_missing_executable_named_error` and `test_missing_executable_reaches_run_failed_trail` in the same suite
- Tests (file exists but not executable): `test_non_executable_permission_error` in the same suite
- Test (session stays alive across a cli failure): `test_session_alive_runs_new_run_after_cli_failure` in the same suite
- Note: the three failure-mode cases assert the run reaches `run.failed` with the right named reason; the session-survival assertion lives in the dedicated survival case (it drives a run to `run.failed`, asserts `is_process_alive(SessionPid)`, then completes a fresh run). The contract lists them together so the "fails and the session survives" line resolves to a real pair, not one overloaded case.

### Criterion 8 — a hanging cli tool times out and its external OS process is gone
- Call chain: test → `soma_agent_session:start_run/2` → `soma_run` arms the per-step `state_timeout` → helper sleeps past it → timer fires → `soma_run` kills the worker → `run.timeout`
- Test entry: `soma_agent_session:start_run/2`
- Test (reaches timeout): `test_cli_overrun_reaches_timeout` in `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`
- Test (external process dead): `test_cli_external_process_dead_after_timeout` in the same suite, proven by the absence of a marker file the helper would only touch if it had survived to finish its sleep

### Criterion 9 — cancelling a run with an active cli tool stops the external process and reaches cancelled
- Call chain: test → `soma_agent_session:start_run/2` → `soma_run` reaches `waiting_tool` → `SessionPid ! {cancel_run, RunId}` → session forwards `cancel` to `soma_run` → run kills the worker → `run.cancelled`
- Test entry: `soma_agent_session:start_run/2` then the README-named `{cancel_run, RunId}` message to the session
- Test (reaches cancelled): `test_cli_cancel_reaches_cancelled` in `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`
- Test (external process dead): `test_cli_external_process_dead_after_cancel` in the same suite, same marker-file liveness check as the timeout case

### Criterion 10 — after failed/timeout/cancelled, the same session completes a fresh run
- Call chain: test → `soma_agent_session:start_run/2` (first run to a terminal state) → assert `is_process_alive(SessionPid)` → `soma_agent_session:start_run/2` again on the same session → `run.completed`
- Test entry: `soma_agent_session:start_run/2`, twice on one session pid
- Test (after timeout): `test_session_alive_runs_new_cli_run_after_timeout` in `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`
- Test (after cancel): `test_session_alive_runs_new_cli_run_after_cancel` in the same suite
- Test (after failure): `test_session_alive_runs_new_run_after_cli_failure` in `apps/soma_runtime/test/soma_cli_failure_SUITE.erl`

### Criterion 11 — every listed proof resolves to a real passing test; gaps closed
- This is satisfied by the map above. The one gap (criterion 2's does-not-resolve half) is closed by the new `test_register_tool_rejects_missing_field_name_unresolvable` case. No other proof is unmapped.

### Criterion 12 — `rebar3 eunit && rebar3 ct` green at HEAD
- Call chain: none (build-gate assertion)
- Test entry: the merge gate runs both commands
- At HEAD before the new case: EUnit 54, CT 61, both green. After Dev adds the one EUnit case, EUnit is 55. CT covers the cli runtime/process guarantees (the four cli suites); EUnit covers manifest validation (`soma_tool_manifest_tests`) and registry behaviour (`soma_tool_registry_tests`).

## Risks & trade-offs

The contract is a map, not new behaviour, so it can drift: rename a case or delete
an assertion and the doc points at something that no longer proves what it claims.
There is no mechanical check that a named case still exists. The manifest doc
already has doc-content tests (`soma_tool_manifest_doc_tests`); the contract doc
does not get the same treatment here, because asserting "case X exists and asserts
Y" from a test is brittle and out of scope for this issue. The mitigation is that
every name in the doc is copied from a case that runs in the gate, so a deleted
case shows up as a gate failure elsewhere, even if not as a doc-drift failure.

Criterion 6 resolves to two cases rather than one. That is weaker than the v0.1
Erlang trail proof, which asserts the whole ordered trail in one case. The two cli
cases together do cover the four events, but a reader has to hold both in mind to
see the full trail. The contract states this split plainly rather than papering
over it. Tightening it into one ordered assertion is a small follow-up, not part
of this issue's criteria.

The new registry case enters at `register_tool/1`, the runtime registration entry,
not at a session run. That is the right entry for this proof: the proof is about
what the registry does with a bad manifest, and a run never reaches the registry
with an unregistered name in a way that would exercise the rejection. Entering at
`register_tool/1` is on the real caller path for tool registration, not a bypass.

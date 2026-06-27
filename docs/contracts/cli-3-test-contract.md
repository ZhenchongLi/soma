# CLI.3 Test Contract — `soma status` + `soma trace` read commands over the Lisp wire

This document maps each proof of the CLI.3 slice (issue #124) to the suite or
module and the case that proves it. It is the companion to
[cli-2-test-contract.md](cli-2-test-contract.md),
[cli-1b-test-contract.md](cli-1b-test-contract.md) and
[cli-test-contract.md](cli-test-contract.md), and follows the same shape as the
v0.x contracts ([v0.5-test-contract.md](v0.5-test-contract.md),
[v0.6-test-contract.md](v0.6-test-contract.md)).

## What this slice builds

The CLI gains two read commands over the same local Unix socket. `soma trace
<corr>` ships a `(trace "<corr>")` s-expr and `soma status <id>` ships a
`(status "<id>")` s-expr; the daemon compiles each with `soma_lfe:compile/2`
(two new forms — `soma_lfe_parser:parse_trace/1` → `#{trace => #{correlation_id
=> …}}` and `soma_lfe_parser:parse_status/1` → `#{status => #{task_id => …}}`,
routed by `soma_lfe:dispatch/1`), and `soma_cli_server:handle_lisp_request/3`
branches on the distinct top-level key. The `trace` branch renders the
correlation's event chain in timestamp order through `soma_trace:render_lisp/2`
wrapped in a `(trace …)` head, ending (for a completed run) with `run.completed`.
The `status` branch looks the task up with `soma_event_store:by_session/2` (the
run path aliases `session_id => TaskId`), derives the terminal `(state …)` from
the chain — `completed` / `failed` / `timeout` / `cancelled`, or `unknown` for an
empty chain — and renders a `(status …)` reply; an unknown id reports `(state
unknown)` without crashing the handler. The renderer also gains a `(task-id …)`
sub-form in `(result …)` (`soma_lisp:result_pairs/1`) so a `soma run` reply
carries the task id a client feeds back into `soma status`. Both read handlers
are read-only against the event store — no `soma_run`, no actor. The gate uses
mock directives only — no real provider, no non-local socket. See
[../../design-124.md](../../design-124.md).

## Proving suites and modules

- **`soma_lfe_read_tests`** — EUnit module in `apps/soma_lfe/test/`. Exercises
  the pure compile boundary `soma_lfe:compile/2` on the new `(trace …)` and
  `(status …)` forms, asserting each compiles to its own distinct command map
  key.
- **`soma_lisp_tests`** — EUnit module in `apps/soma_event_store/test/`.
  Exercises the pure renderer `soma_lisp:render/1` on a result map carrying
  `task_id`, asserting it emits a `(task-id …)` sub-form.
- **`soma_cli_server_SUITE`** — CT suite in `apps/soma_actor/test/`. Drives the
  full read chains through a real `gen_tcp` client over a temp Unix socket: a
  `(run …)` runs first, then `(trace "<corr>")` / `(status "<task>")` read back
  the real chain — accept loop → `handle_lisp_request/3` → `soma_lfe:compile/2` →
  `soma_trace:render_lisp/2` / `by_session/2` → `soma_lisp:render/1` → framed
  reply. No layer bypassed.
- **`soma_cli_SUITE`** — CT suite in `apps/soma_actor/test/`. Drives the
  `soma_cli` client (`trace/1`, `status/1`) against a real `soma_cli_server` on a
  temp socket, after seeding a chain/task with a `(run …)`.
- **`soma_cli_md_read_tests`** — EUnit module in `apps/soma_actor/test/`. Pins
  the `docs/cli.md` prose documenting the status + trace wire and the
  cancel/`--detach` deferral.
- **`soma_cli_3_contract_tests`** — EUnit module in `apps/soma_actor/test/`.
  Pins this contract doc (`docs/contracts/cli-3-test-contract.md`): asserts the
  file exists, is non-empty, and names every CLI.3 suite/module together with
  each of its case names.
- **`soma_cli_3_marker_tests`** — EUnit module in `apps/soma_actor/test/`. A
  source scan of the CLI.3 test files for real-provider / non-local-socket
  markers.

## CLI.3 proofs → cases

| Criterion | Proof | Suite / module | Case |
| --- | --- | --- | --- |
| 1 | `soma_lfe:compile/2` on `(trace "c-1")` returns `{ok, #{trace => #{correlation_id => <<"c-1">>}}}` — a distinct trace command | `soma_lfe_read_tests` | `test_trace_compiles_to_trace_command` |
| 2 | `soma_lfe:compile/2` on `(status "t-1")` returns `{ok, #{status => #{task_id => <<"t-1">>}}}` — a distinct status command | `soma_lfe_read_tests` | `test_status_compiles_to_status_command` |
| 3 | `soma_lisp:render/1` on a result map carrying `task_id` emits a `(task-id …)` sub-form inside `(result …)` | `soma_lisp_tests` | `test_render_result_map_with_task_id_emits_task_id_subform` |
| 4 | A completed run's `(trace …)` reply carries its events in timestamp order, ending with `run.completed` | `soma_cli_server_SUITE` | `test_trace_after_run_returns_ordered_chain_ending_completed` |
| 5 | A completed run's `(status …)` reply reports `(state completed)` | `soma_cli_server_SUITE` | `test_status_after_run_reports_state_completed` |
| 6 | `(status "no-such-id")` reports `(state unknown)` and the server stays up for the next connection | `soma_cli_server_SUITE` | `test_status_unknown_id_reports_unknown_and_server_survives` |
| 7 | `soma_cli:trace/1` prints the `(trace …)` reply and returns exit 0 | `soma_cli_SUITE` | `test_trace_prints_reply_exit_zero` |
| 8 | `soma_cli:status/1` prints the `(status …)` reply and returns exit 0 | `soma_cli_SUITE` | `test_status_prints_reply_exit_zero` |
| 9 | `docs/cli.md` documents the `(trace …)`/`(status …)` requests and replies and records the `soma cancel <id>` / `--detach` deferral | `soma_cli_md_read_tests` | `test_cli_md_documents_status_trace_and_defers_cancel_detach` |
| 10 | This contract (`docs/contracts/cli-3-test-contract.md`) names a suite/module + case for each CLI.3 proof | `soma_cli_3_contract_tests` | `test_doc_names_cli_3_suites_and_cases` (the mapping table above is the deliverable) |
| 11 | CLI.3 test sources carry no real-provider marker and open no non-local socket | `soma_cli_3_marker_tests` | `test_cli_3_sources_have_no_real_provider_or_socket_marker` |
| 12 | `rebar3 dialyzer` is run and its result reported | _build step_ | none (PR body text carried in [cli-3-dialyzer-pr-report.md](cli-3-dialyzer-pr-report.md); the project does not gate dialyzer, baseline 4 warnings) |

## Notes for the auditor

- **Criteria 9, 10 and 12 are not in-suite proofs.** Criterion 10 is this file
  itself; it is pinned by
  `soma_cli_3_contract_tests:test_doc_names_cli_3_suites_and_cases`, which fails
  if any suite/module or case name above goes missing. Criterion 9 is satisfied
  by the prose in `docs/cli.md` and additionally pinned by
  `soma_cli_md_read_tests`. Criterion 12 is a build step reported in the PR body,
  not a test function; until GitHub has a PR for this branch, the PR-ready body
  text is carried in
  [cli-3-dialyzer-pr-report.md](cli-3-dialyzer-pr-report.md) and pinned by
  `soma_cli_3_contract_tests:test_cli_3_dialyzer_pr_report_is_carried_locally`.
- **Status leans on the run path aliasing `session_id` to the task id.** The
  status lookup uses `by_session/2` because the run path sets `session_id =>
  TaskId`; there is no `by_task` query in this slice. If a future change stops
  aliasing, status would silently return `unknown` — the honest fix then is a
  `by_task` query. This coupling is intentional scope, recorded here so it is not
  a surprise later.
- **Ask tasks are not reachable by status the same way.** An ask task runs
  through an actor and its events are stamped by correlation id, not by the task
  id as a session id, so `status` on an ask task id returns `unknown`. The
  criteria only assert status for a run task; this is a known limit, not a bug.
- **The trace reply's "ending event" is the highest-timestamp event.**
  `render_lisp/2` sorts by timestamp ascending; for a completed run the tail is
  `run.completed`. Criterion 4 asserts `run.completed` is present and last, not
  that no two events could ever tie at nanosecond resolution.
- **The mock is the gate default.** Every CLI.3 server/client case is seeded by a
  run over the local socket and the read commands are read-only against the event
  store — no real provider, no non-local socket. `soma_cli_3_marker_tests` guards
  it.
- **The `soma` escript/release entry is thin glue** over `soma_cli` and is
  exercised by the end-to-end path, not unit-tested, per the issue's out-of-scope
  note.

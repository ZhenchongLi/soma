# Baseline cleanup: make Dialyzer green and align current-state docs

## Current state

The OTP 29 baseline is green at 380 EUnit tests and 425 Common Test cases. A
fresh `rebar3 eunit` in this worktree confirms the 380 EUnit count. The refined
issue records the 425 Common Test count. The status lines in `README.md` and
`AGENTS.md` still say 342 and 354.

`rebar3 dialyzer` currently exits non-zero with six warnings. They come from
four small control-flow mismatches:

- `soma_lfe_reader` has three dead parser branches. `parse_all_forms/3` is only
  called with an empty stack. Its remaining stack/error clauses cannot run
  because the reachable empty-stack clauses already cover every call.
  `parse_form/1` is called only after its two callers have handled an empty
  token list, so its empty-list clause cannot run either.
- `soma_run:cli_argv_placeholder_name/1` has a catch-all clause after binary
  and list clauses. Success typing narrows the production callers to binary or
  list argv elements, which makes that final clause dead to Dialyzer.
- `soma_run_auto_resume:resume_interrupted/1` builds a list of resume results
  and then discards the list. The return values are intentionally not boot
  outcomes, but that intent is not expressed in the control flow.
- `soma_tool_call:await_cli/3` sends the external OS pid to the owning run. The
  send expression returns the sent tuple. The surrounding case discards that
  structured return before entering `collect_cli/3`.

The warned code already has behavior coverage. Reader behavior enters through
`soma_lfe_reader:read_forms/1`. CLI placeholder rendering enters through a real
session and run in `soma_cli_placeholder_SUITE`. Boot resume enters through the
application callback in `soma_run_auto_resume_SUITE`. The OS-pid notification
is load-bearing in `soma_cli_lifecycle_SUITE`: the timeout and cancel tests only
keep their marker files absent when the run received the child pid and killed
the external process.

The current-state docs have four other gaps. `docs/design.md` still calls the
CLI/config planning surface future work even though #199 shipped it.
`AGENTS.md` still lists structured real-model planning as open and out of
scope. The Chinese overview stops at v0.7.4 and calls boot auto-resume future
work. The CLI.3 contract still describes its four-warning result as a baseline
rather than evidence captured on 2026-06-27.

`CLAUDE.md` is also a second, stale copy of repository guidance. Three EUnit
tests currently read unique crash and actor-registry facts from that file.
Reducing it to `@AGENTS.md` without moving those facts and retargeting those
tests would make the normal gate fail and would discard guidance that earlier
issues pinned.

## Approach

Keep the runtime edits local to the four warned functions. Do not change
Dialyzer configuration and do not add warning suppressions.

For `soma_lfe_reader`, remove the stack argument from the internal
`parse_all_forms` recursion. Keep the empty-token success clause and the
non-empty-token parse clause. Remove the unreachable `parse_form([])` clause.
The reachable unclosed-list diagnostic remains owned by `parse_list([], Acc)`.
Add one reader test that pins empty input, multiple top-level forms, an
unexpected close parenthesis, and an unclosed parenthesis. This protects the
reader results while the dead branches are removed.

For `soma_run`, keep the binary placeholder parser unchanged. Fold the guarded
list clause and the final fallback into one total non-binary path. That path
attempts Unicode conversion, follows the binary parser when conversion returns
a binary, and returns `none` for an incomplete conversion, an error result, or
`badarg`. This removes the top-level clause Dialyzer proves unreachable while
preserving the old fallback for malformed terms. Do not widen manifest rules or
change when a valid CLI step starts its worker.

For `soma_run_auto_resume`, replace the result-producing list comprehension
with ordered iteration. Bind each `soma_run_resume_executor:resume/3` result to
an intentionally ignored value inside the callback, then return `ok`. Every
interrupted run is still handed to the same executor in discovery order. A
raised exception still stops boot as it does today. Ordinary executor verdicts
remain non-fatal to the coordinator.

For `soma_tool_call`, make the OS-pid notification case return `ok` on both
branches. Match that `ok` before calling `collect_cli/3`. The message send must
stay in the production `port_info(Port, os_pid)` branch and must happen before
the worker blocks in the collect loop. No test-only callback or exported seam
is needed.

Use `rebar3 dialyzer` itself as the static-analysis proof for all four modules.
Run it on OTP 29 over the whole umbrella. Pair that proof with the reader
regression case and the existing placeholder, auto-resume, and CLI lifecycle
cases. Then run the normal `rebar3 eunit && rebar3 ct` gate.

Add `soma_baseline_cleanup_doc_tests` under `apps/soma_runtime/test/`. It reads
the named files directly and has five cases: one shared totals case, one exact
`CLAUDE.md` case, and one case for each current-state document. Together with
the new reader case, this design adds six EUnit cases and no Common Test cases.
The expected final count is therefore 386 EUnit and 425 Common Test. The output
from the final green commands is authoritative. If the runner reports a
different count, update the test literal and both status docs to the displayed
pair rather than preserving the arithmetic estimate.

Update the docs as follows:

- Record the final EUnit and Common Test totals in both `README.md` and
  `AGENTS.md`.
- Make `CLAUDE.md` contain exactly `@AGENTS.md` plus its terminating newline.
- Move the `soma_actor_registry`, atomic `spawn_monitor`, real-exit-reason, and
  `noproc` guidance that is currently pinned in `CLAUDE.md` into the matching
  architecture paragraphs in `AGENTS.md`. Retarget
  `soma_crash_reason_docs_tests` to that authoritative file.
- In `docs/design.md`, put CLI/config productization of real-model planning in
  the built list and remove it from `Still open`.
- In `AGENTS.md`, name structured real-model planning and its CLI/config
  surface as built. Remove it from the open-track sentence and the out-of-scope
  list. Add it to the current-core list.
- In `docs/zh/what-is-soma.zh.md`, describe v0.7.1 through v0.7.5 as built.
  Name interrupted-run discovery and boot auto-resume. Remove boot auto-resume
  from the future-work wording.
- In `docs/contracts/cli-3-test-contract.md` and
  `docs/contracts/cli-3-dialyzer-pr-report.md`, call the four-warning result a
  historical snapshot captured on 2026-06-27. State that it is not the current
  branch status. Rename the existing source-read assertion to match that
  meaning.

## Acceptance criteria → tests

### Criterion 1 — `soma_lfe_reader` has no OTP 29 Dialyzer warning
- Call chain: none (compile-time assertion). `rebar3 dialyzer` analyzes the
  scanner and parser call graph from `read_forms/1`.
- Test entry: `rebar3 dialyzer`. The companion behavior test enters at the
  public `soma_lfe_reader:read_forms/1` boundary.
- Code boundary: `apps/soma_lfe/src/soma_lfe_reader.erl` internal
  `parse_all_forms` and `parse_form` clauses
- Responsibility owner: `soma_lfe_reader` owns token-to-form parsing and reader
  diagnostics
- Test: `rebar3 dialyzer` configured in `rebar.config`. The behavior test is
  `test_parser_cleanup_preserves_reader_results` in
  `apps/soma_lfe/test/soma_lfe_reader_tests.erl`.

### Criterion 2 — `soma_run` has no OTP 29 Dialyzer warning
- Call chain: `soma_agent_session:start_run/2` → `soma_run:executing/3` →
  `prepare_cli_argv_placeholders/2` → `render_cli_argv/3` →
  `render_cli_argv_placeholder/3` → `cli_argv_placeholder_name/1`
- Test entry: `rebar3 dialyzer` for the warning. The behavior regression enters
  at `soma_agent_session:start_run/2` with a normalized CLI descriptor.
- Code boundary: `apps/soma_runtime/src/soma_run.erl`
  `cli_argv_placeholder_name/1`
- Responsibility owner: `soma_run` owns resolved placeholder substitution
  before the tool-call boundary
- Test: `rebar3 dialyzer` configured in `rebar.config`. The behavior test is
  `test_cli_argv_placeholder_renders_string_integer_boolean` in
  `apps/soma_runtime/test/soma_cli_placeholder_SUITE.erl`.

### Criterion 3 — `soma_run_auto_resume` has no OTP 29 Dialyzer warning
- Call chain: `soma_app:start/2` → `maybe_resume_interrupted/0` →
  `soma_run_auto_resume:resume_interrupted/1` →
  `soma_event_store:interrupted_runs/1` →
  `soma_run_resume_executor:resume/3`
- Test entry: `rebar3 dialyzer` for the warning. The behavior regression starts
  `soma_runtime` with a durable event log, so no boot layer is skipped.
- Code boundary: `apps/soma_runtime/src/soma_run_auto_resume.erl`
  `resume_interrupted/1`
- Responsibility owner: `soma_run_auto_resume` owns boot-time iteration over
  discovered run ids. The executor continues to own each resume outcome.
- Test: `rebar3 dialyzer` configured in `rebar.config`. The behavior tests are
  `test_boot_with_event_store_log_resumes_between_steps_interrupted_run` and
  `test_boot_auto_resume_fails_unsafe_in_flight_state_step` in
  `apps/soma_runtime/test/soma_run_auto_resume_SUITE.erl`.

### Criterion 4 — the full umbrella Dialyzer run is green, including OS-pid notification
- Call chain: `soma_agent_session:start_run/2` → `soma_run:start_tool_call/7` →
  `soma_tool_call:start/1` → `run_cli/6` → `await_cli/3` →
  `erlang:port_info/2` → `{tool_started_os_pid, ...}` message →
  `soma_run:waiting_tool/3` stores the pid → timeout or cancel →
  `kill_os_process/1`
- Test entry: `rebar3 dialyzer` for the full umbrella. The behavior tests enter
  at `soma_agent_session:start_run/2` and use a real external helper.
- Code boundary: the four warned source files under `apps/soma_lfe/src/` and
  `apps/soma_runtime/src/`, with the OS-pid return cleanup in
  `soma_tool_call:await_cli/3`
- Responsibility owner: `soma_tool_call` owns port creation and pid reporting.
  `soma_run` owns external-process teardown.
- Test: `rebar3 dialyzer` configured in `rebar.config`. The behavior tests are
  `test_cli_external_process_dead_after_timeout` and
  `test_cli_external_process_dead_after_cancel` in
  `apps/soma_runtime/test/soma_cli_lifecycle_SUITE.erl`.

### Criterion 5 — README reports the final green gate totals
- Call chain: none (direct source-file read)
- Test entry: off chain. The test reads `README.md` after the final gate because
  this criterion is release-state evidence, not a runtime path.
- Code boundary: `README.md` status line and
  `apps/soma_runtime/test/soma_baseline_cleanup_doc_tests.erl`
- Responsibility owner: `README.md` owns the public high-level status
- Test: `test_readme_and_agents_report_final_green_gate_totals` in `apps/soma_runtime/test/soma_baseline_cleanup_doc_tests.erl`

### Criterion 6 — AGENTS reports the final green gate totals
- Call chain: none (direct source-file read)
- Test entry: off chain. The same totals test reads `AGENTS.md` and requires the
  exact pair pinned for README.
- Code boundary: `AGENTS.md` current-state status and
  `soma_baseline_cleanup_doc_tests.erl`
- Responsibility owner: `AGENTS.md` owns repository-local agent guidance
- Test: `test_readme_and_agents_report_final_green_gate_totals` in `apps/soma_runtime/test/soma_baseline_cleanup_doc_tests.erl`

### Criterion 7 — CLAUDE contains only the AGENTS import
- Call chain: none (direct source-file read)
- Test entry: off chain. The test compares the complete file bytes to
  `@AGENTS.md\n`. Existing guidance tests read `AGENTS.md` after the migration.
- Code boundary: `CLAUDE.md`, the matching architecture text in `AGENTS.md`,
  and `apps/soma_actor/test/soma_crash_reason_docs_tests.erl`
- Responsibility owner: `CLAUDE.md` owns only the import. `AGENTS.md` owns the
  imported guidance.
- Test: `test_claude_md_contains_only_agents_import` in
  `apps/soma_runtime/test/soma_baseline_cleanup_doc_tests.erl`. The retargeted
  actor-registry and crash-reason cases remain in
  `apps/soma_actor/test/soma_crash_reason_docs_tests.erl`.

### Criterion 8 — design.md lists CLI/config real-model planning as built
- Call chain: none (direct source-file read)
- Test entry: off chain. The test reads the `Current Scope` section and checks
  the built list and the open list.
- Code boundary: `docs/design.md` `Current Scope` section
- Responsibility owner: `docs/design.md` owns the north-star scope summary
- Test: `test_design_lists_cli_config_real_planning_as_built` in `apps/soma_runtime/test/soma_baseline_cleanup_doc_tests.erl`

### Criterion 9 — AGENTS lists structured real-model planning as built
- Call chain: none (direct source-file read)
- Test entry: off chain. The test reads the current-state and scope sections and
  rejects the old open-track classification.
- Code boundary: `AGENTS.md` current-state and scope sections
- Responsibility owner: `AGENTS.md` owns the built/open guidance used by coding
  agents
- Test: `test_agents_lists_structured_real_model_planning_as_built` in `apps/soma_runtime/test/soma_baseline_cleanup_doc_tests.erl`

### Criterion 10 — the Chinese overview lists v0.7.5 boot auto-resume as built
- Call chain: none (direct source-file read)
- Test entry: off chain. The test reads the Chinese overview and checks the
  v0.7.5 built wording while rejecting its former future-work sentence.
- Code boundary: `docs/zh/what-is-soma.zh.md`
- Responsibility owner: the Chinese overview owns its translated current-state
  summary
- Test: `test_zh_overview_lists_v0_7_5_boot_auto_resume_as_built` in `apps/soma_runtime/test/soma_baseline_cleanup_doc_tests.erl`

### Criterion 11 — CLI.3 labels the four-warning result as historical
- Call chain: none (direct source-file read)
- Test entry: off chain. The existing CLI.3 contract test reads the contract and
  its Dialyzer report.
- Code boundary: `docs/contracts/cli-3-test-contract.md`,
  `docs/contracts/cli-3-dialyzer-pr-report.md`, and
  `apps/soma_actor/test/soma_cli_3_contract_tests.erl`
- Responsibility owner: the CLI.3 contract material owns the meaning and date
  of its recorded build evidence
- Test: `test_cli_3_dialyzer_report_is_2026_06_27_historical_snapshot` in `apps/soma_actor/test/soma_cli_3_contract_tests.erl`

## Risks & trade-offs

- Removing dead reader branches can accidentally change which diagnostic owns
  end-of-input. The reader regression case must pin the reachable public
  results, not private function names.
- The `soma_run` warning is based on a narrowed production type, but the current
  helper returns `none` for other terms. A bare deletion of the fallback would
  turn an out-of-contract argv element into a run-process crash earlier in the
  path. The total non-binary conversion keeps the fallback without a dead
  top-level clause.
- Boot auto-resume intentionally ignores ordinary executor verdicts. Treating a
  returned `{error, _}` as an application-start failure would change v0.7.5
  behavior. Ordered iteration should express the ignored value and nothing
  more.
- The OS-pid send expression returns the message tuple. Converting the branch
  result to `ok` must not replace or move the send. The lifecycle marker tests
  catch that regression because an unreported child survives timeout or cancel.
- Truncating `CLAUDE.md` without first moving its unique pinned facts would make
  `@AGENTS.md` a lossy import. Retargeting the old tests keeps one authoritative
  source without weakening the earlier crash-reason contract.
- New EUnit cases change the number the docs need to report. Update the totals
  only after the complete test inventory is present and the final commands have
  printed their counts.
- Dialyzer PLTs are OTP-version dependent. The acceptance proof must be captured
  on OTP 29. A green run on another OTP release does not replace that evidence.

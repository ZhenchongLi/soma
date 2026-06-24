### Claude

## Verdict
changes-requested

## Real issues

1. **`soma_lfe_runtime_SUITE` does not exist.** The seven runtime contract cases (R1–R7) described in `design-42.md` are not implemented. There is no CT suite in `apps/soma_runtime/test/` that feeds compiled DSL steps to `soma_agent_session:start_run/2`. The full runtime half of this issue — distinct worker pids from DSL source, event trail, fail/timeout/cancel semantics, session survival after each terminal state — is unproven.

2. **`docs/lfe-dsl.md` does not exist.** No file at that path. The syntax reference, step-list contract, `file_read -> echo -> file_write` DSL example, `from_step` forms, diagnostic codes, and non-goals are all absent.

3. **`README.md` not updated.** The file still lists v0.3 as a future layer. It has no description of the LFE DSL as a built compile-only layer and no reference to `docs/lfe-dsl.md`.

4. **`docs/roadmap.md` not updated.** v0.3 is still marked as a future item. Once the suite is green this must flip to done.

## Questions

The design says criterion C6 ("compile failure does not start a run and does not emit runtime events") is already covered by `test_invalid_dsl_does_not_start_run` in `soma_lfe_validation_tests`. That test checks `whereis(soma_sup) =:= undefined` before and after a failed compile — it does not check that no runtime events were emitted. If `soma_runtime` is running (e.g., in a shared CT node), that assertion tells you nothing about events. The coverage claim may be narrower than the criterion implies. Dev should verify this, or add an explicit check.

## Nits

- `design-42.md` notes that R7 in the existing suites uses separate cases (`test_session_runs_new_run_after_failed`, `_after_timeout`, `_after_cancelled`). The design leaves the split decision to Dev but suggests matching that pattern. Following it consistently would make failure attribution cleaner.

## Functional evidence

- Criterion 1 (`rebar3 eunit` and `rebar3 ct` pass) — pass: 95 EUnit / 61 CT, all green. But these are the pre-existing tests from `main`; no new tests for this issue exist yet.
- Criterion 2 (docs describe compiler as compile-only layer) — fail: `docs/lfe-dsl.md` does not exist.
- Criterion 3 (proof-to-test mapping prevents DSL/runtime confusion) — fail: `soma_lfe_runtime_SUITE` does not exist; no mapping is possible.
- Criterion R1 (DSL demo compiles and runs to `run.completed`) — fail: `soma_lfe_runtime_SUITE` missing.
- Criterion R2 (compiled demo produces the normal event trail) — fail: `soma_lfe_runtime_SUITE` missing.
- Criterion R3 (each tool call has its own worker pid) — fail: `soma_lfe_runtime_SUITE` missing.
- Criterion R4 (compiled `fail` step fails run, session survives) — fail: `soma_lfe_runtime_SUITE` missing.
- Criterion R5 (compiled `sleep` step can be timed out) — fail: `soma_lfe_runtime_SUITE` missing.
- Criterion R6 (compiled `sleep` step can be cancelled) — fail: `soma_lfe_runtime_SUITE` missing.
- Criterion R7 (session starts fresh run after DSL-sourced terminal state) — fail: `soma_lfe_runtime_SUITE` missing.
- Criterion C1 (duplicate step ids fail compilation) — pass: `soma_lfe_validation_tests:test_duplicate_step_id_returns_diagnostic` passes, returns `{error, [#{code => duplicate_step_id, ...}]}`.
- Criterion C2 (unknown `from_step` references fail compilation) — pass: `soma_lfe_validation_tests:test_unknown_from_step_returns_diagnostic` passes, returns `{error, [#{code => invalid_from_step, ...}]}`.
- Criterion C3 (forward `from_step` references fail compilation) — pass: `soma_lfe_validation_tests:test_forward_from_step_returns_diagnostic` passes, returns `{error, [#{code => invalid_from_step, ...}]}`.
- Criterion C4 (invalid timeout values fail compilation) — pass: `soma_lfe_validation_tests:test_invalid_timeout_returns_diagnostic` passes for both `timeout_ms 0` and string timeout.
- Criterion C5 (unknown DSL forms fail compilation) — pass: `soma_lfe_validation_tests:test_unknown_form_returns_diagnostic` passes, returns `{error, [#{code => unknown_form, ...}]}`.
- Criterion C6 (compile failure does not start a run, no runtime events) — pass (partial): `test_invalid_dsl_does_not_start_run` checks `soma_sup` is absent before and after a failed compile. Event-emission side of this criterion is not tested.
- Criterion D1 (`docs/lfe-dsl.md` covers syntax, step-list contract, demo, `from_step`, diagnostics, non-goals) — fail: file does not exist.
- Criterion D2 (`README.md` and `docs/roadmap.md` updated) — fail: `README.md` still lists v0.3 as future; `docs/roadmap.md` still shows v0.3 as not done.

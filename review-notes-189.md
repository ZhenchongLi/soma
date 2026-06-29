### Claude

## Verdict

Changes requested. The compiler/test work mostly lands the bounded `(task ...)`
surface, but the docs acceptance set is not actually complete: `docs/cli.md`
still documents `soma run` as an LFE `(run ...)` workflow path, and the new doc
test file never checks `docs/cli.md`.

## Real issues

1. `docs/cli.md` misses the required public wording for `soma run FILE`.

   The issue requires `docs/cli.md` to describe `soma run FILE` as reading Soma
   Lisp source. This branch does not modify `docs/cli.md`; the current text still
   says `soma run <workflow>` runs an "LFE workflow" and that the file is "a
   `(run ...)` s-expr" at `docs/cli.md:90` and `docs/cli.md:105`. That is exactly
   the old surface the issue is trying to demote. The test gap is visible in
   `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:85`, which checks
   `docs/usage.md` but has no corresponding `docs/cli.md` assertion. So the
   branch can go green while failing one explicit acceptance criterion.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] A single `(task ...)` top-level form compiles through `soma_lfe:compile/2` to `#{run => #{steps => Steps}}`.
  Evidence: `apps/soma_lfe/src/soma_lfe.erl:29` dispatches `(task ...)` to `parse_task/1`; `apps/soma_lfe/src/soma_lfe_parser.erl:72` returns `#{run => #{steps => Steps}}`; covered by `soma_lfe_task_tests:test_task_compiles_to_run_steps/0`.

- [x] Each `let*` binding becomes one runtime step in binding order.
  Evidence: `parse_task_bindings/3` accumulates parsed steps and reverses once at `apps/soma_lfe/src/soma_lfe_parser.erl:99`; covered by `soma_lfe_task_tests:test_let_star_bindings_preserve_order/0`.

- [x] A binding name becomes the runtime step `id`.
  Evidence: `apps/soma_lfe/src/soma_lfe_parser.erl:190` writes `id => Id`; covered by `soma_lfe_task_tests:test_binding_name_becomes_step_id/0`.

- [x] A `(tool ToolName ...)` call becomes the runtime step `tool`.
  Evidence: `apps/soma_lfe/src/soma_lfe_parser.erl:117` accepts atom tool names and `apps/soma_lfe/src/soma_lfe_parser.erl:190` writes `tool => Tool`; covered by `soma_lfe_task_tests:test_tool_call_becomes_step_tool/0`.

- [x] Literal `(Key Value)` task arguments use the existing coercions for strings, atoms, integers.
  Evidence: task args flow through existing `parse_args/2` after rewrite at `apps/soma_lfe/src/soma_lfe_parser.erl:250`; `coerce_value/1` handles binary, integer, and atom at `apps/soma_lfe/src/soma_lfe_parser.erl:666`; covered by `soma_lfe_task_tests:test_literal_task_args_use_existing_coercions/0`.

- [x] `(from Name)` as the only tool argument lowers to `#{from_step => Name}`.
  Evidence: `apps/soma_lfe/src/soma_lfe_parser.erl:243`; covered by `soma_lfe_task_tests:test_bare_from_lowers_to_from_step/0`.

- [x] `(Key (from Name))` lowers to `Key => {from_step, Name}`.
  Evidence: `apps/soma_lfe/src/soma_lfe_parser.erl:264` rewrites to the existing `from_step` value shape; covered by `soma_lfe_task_tests:test_field_from_lowers_to_from_step_tuple/0`.

- [x] `(timeout-ms N)` lowers to `timeout_ms => N` on the step map.
  Evidence: `apps/soma_lfe/src/soma_lfe_parser.erl:207`; covered by `soma_lfe_task_tests:test_timeout_ms_lowers_to_step_timeout_ms/0`.

- [x] `(return Name)` validates that `Name` has already been bound.
  Evidence: `validate_task_return/2` checks the parsed step ids at `apps/soma_lfe/src/soma_lfe_parser.erl:292`; success path is exercised by the positive task tests.

- [x] Duplicate binding names fail with a `duplicate_binding` diagnostic.
  Evidence: `check_duplicate_bindings/1` emits `duplicate_binding` at `apps/soma_lfe/src/soma_lfe_parser.erl:274`; covered by `soma_lfe_task_tests:test_duplicate_binding_returns_diagnostic/0`.

- [x] Unknown `(from Name)` references fail with an `invalid_from_binding` diagnostic.
  Evidence: task validation remaps `check_from_step_refs/1` diagnostics to `invalid_from_binding` at `apps/soma_lfe/src/soma_lfe_parser.erl:289`; covered by `soma_lfe_task_tests:test_unknown_from_binding_returns_diagnostic/0`.

- [x] Forward `(from Name)` references fail with an `invalid_from_binding` diagnostic.
  Evidence: same ordered validation path at `apps/soma_lfe/src/soma_lfe_parser.erl:289`; covered by `soma_lfe_task_tests:test_forward_from_binding_returns_diagnostic/0`.

- [x] Missing `(return Name)` bodies fail with an `invalid_return` diagnostic.
  Evidence: `apps/soma_lfe/src/soma_lfe_parser.erl:90`; covered by `soma_lfe_task_tests:test_missing_return_returns_diagnostic/0`.

- [x] Unknown `(return Name)` references fail with an `invalid_return` diagnostic.
  Evidence: `apps/soma_lfe/src/soma_lfe_parser.erl:292`; covered by `soma_lfe_task_tests:test_unknown_return_returns_diagnostic/0`.

- [x] Invalid `(timeout-ms N)` values fail with an `invalid_timeout` diagnostic.
  Evidence: invalid timeout branches emit `invalid_timeout` at `apps/soma_lfe/src/soma_lfe_parser.erl:220` and `apps/soma_lfe/src/soma_lfe_parser.erl:227`; covered by `soma_lfe_task_tests:test_invalid_timeout_ms_returns_diagnostic/0`.

- [x] Malformed `(task ...)` roots fail with an `invalid_task_form` diagnostic.
  Evidence: `apps/soma_lfe/src/soma_lfe_parser.erl:94`; covered by `soma_lfe_task_tests:test_malformed_task_root_returns_diagnostic/0`.

- [x] Malformed `let*` bodies fail with an `invalid_let_star` diagnostic.
  Evidence: extra-body let* form emits `invalid_let_star` at `apps/soma_lfe/src/soma_lfe_parser.erl:85`; covered by `soma_lfe_task_tests:test_malformed_let_star_returns_diagnostic/0`.

- [x] Malformed bindings fail with an `invalid_binding` diagnostic.
  Evidence: malformed binding branches emit `invalid_binding` at `apps/soma_lfe/src/soma_lfe_parser.erl:123` and `apps/soma_lfe/src/soma_lfe_parser.erl:132`; covered by `soma_lfe_task_tests:test_malformed_binding_returns_diagnostic/0`.

- [x] Malformed `(tool ...)` calls fail with an `invalid_tool_form` diagnostic.
  Evidence: `task_invalid_tool_form_diag/1` is used for malformed tool tails at `apps/soma_lfe/src/soma_lfe_parser.erl:119`; covered by `soma_lfe_task_tests:test_malformed_tool_form_returns_diagnostic/0`.

- [x] Reserved task words fail as binding names with a `reserved_form` diagnostic.
  Evidence: `is_reserved_task_word/1` and `task_reserved_form_diag/1` at `apps/soma_lfe/src/soma_lfe_parser.erl:137`; covered by `soma_lfe_task_tests:test_reserved_binding_name_returns_diagnostic/0`.

- [x] Unsupported task control heads fail with a `reserved_form` diagnostic: `if`, `cond`, `loop`, `recur`.
  Evidence: `find_unsupported_task_control_form/1` and `task_reserved_control_form_diag/1` at `apps/soma_lfe/src/soma_lfe_parser.erl:147`; covered by `soma_lfe_task_tests:test_unsupported_task_control_heads_return_diagnostic/0`.

- [x] README quick start uses `(task ...)` as the primary `soma run` example.
  Evidence: README quick start now writes a `(task ...)` file before `scripts/soma run`; covered by `soma_lfe_task_doc_tests:test_readme_quick_start_uses_task_example/0`.

- [x] `docs/lfe-dsl.md` documents `(task ...)` as the public static task form.
  Evidence: `docs/lfe-dsl.md` has a "Public static task form" section; covered by `soma_lfe_task_doc_tests:test_lfe_dsl_documents_task_as_public_static_form/0`.

- [x] `docs/lfe-dsl.md` documents `(run ...)` as the compatibility/core run form.
  Evidence: `docs/lfe-dsl.md` says `(run ...)` remains the compatibility/core run form; covered by `soma_lfe_task_doc_tests:test_lfe_dsl_documents_run_as_compatibility_core_form/0`.

- [x] `docs/lfe-dsl.md` includes the sentence: `When a need is dynamic, keep the dynamic decision in the actor/planner layer and submit a new bounded static Soma Lisp task for each execution attempt.`
  Evidence: exact sentence asserted by `soma_lfe_task_doc_tests:test_lfe_dsl_includes_dynamic_need_sentence/0`.

- [x] `docs/design.md` states `Soma Lisp source -> soma_lfe:compile/2 -> validated maps -> OTP execution`.
  Evidence: exact sentence asserted by `soma_lfe_task_doc_tests:test_design_documents_soma_lisp_boundary/0`.

- [x] `docs/cli.md` describes `soma run FILE` as reading Soma Lisp source.
  Evidence: not satisfied. `docs/cli.md:105` still describes the input as an LFE `(run ...)` workflow, and no doc test covers `docs/cli.md`.

- [x] `docs/usage.md` describes `soma run FILE` as reading Soma Lisp source.
  Evidence: `docs/usage.md:903`; covered by `soma_lfe_task_doc_tests:test_usage_doc_says_run_file_reads_soma_lisp_source/0`.

Verification run:

- `rebar3 eunit --module=soma_lfe_task_tests` passed: 20 tests, 0 failures.
- `rebar3 eunit --module=soma_lfe_task_doc_tests` passed: 6 tests, 0 failures.
- One initial parallel doc-test run hit a `_build/test` BEAM rename race while another `rebar3 eunit` compile was running; the same command passed immediately when rerun serially.

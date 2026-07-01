# Task Form Test Contract

This contract covers the bounded Soma Lisp v1 public task surface. The task
form is a compile-time edge form: `soma_lfe:compile/2` lowers `(task ...)`
source into the canonical run step-list map and returns diagnostics for invalid
static task shapes. It does not add runtime execution semantics.

## Compile Contract

The compile behavior is proved by `soma_lfe_task_tests`:

| Behavior | Proof |
| --- | --- |
| `(task ...)` lowers to `#{run => #{steps => Steps}}`. | `test_task_compiles_to_run_steps` |
| Bare `(from step_id)` lowers to `#{from_step => StepId}`. | `test_bare_from_lowers_to_from_step` |
| Field-level `(from step_id)` lowers to `{from_step, StepId}`. | `test_field_from_lowers_to_from_step_tuple` |
| `(timeout-ms N)` lowers to step `timeout_ms`. | `test_timeout_ms_lowers_to_step_timeout_ms` |
| Duplicate `let*` bindings return a diagnostic. | `test_duplicate_binding_returns_diagnostic` |
| Forward `from` references return a diagnostic. | `test_forward_from_binding_returns_diagnostic` |
| Unsupported task control heads return diagnostics. | `test_unsupported_task_control_heads_return_diagnostic` |

## Documentation Contract

The public documentation behavior is proved by `soma_lfe_task_doc_tests`:

| Documentation behavior | Proof |
| --- | --- |
| The site quick-start task example compiles as bounded Soma Lisp v1. | `test_site_quick_start_task_example_compiles` |
| The README quick-start presents `(task ...)` before `soma run`. | `test_readme_quick_start_uses_task_example` |
| `docs/lfe-dsl.md` names `(task ...)` as the public static task form. | `test_lfe_dsl_documents_task_as_public_static_form` |
| `docs/lfe-dsl.md` names `(run ...)` as the compatibility/core run form. | `test_lfe_dsl_documents_run_as_compatibility_core_form` |
| `docs/lfe-dsl.md` keeps dynamic decisions above the static task form. | `test_lfe_dsl_includes_dynamic_need_sentence` |
| `docs/design.md` records the Soma Lisp compile boundary. | `test_design_documents_soma_lisp_boundary` |
| `docs/usage.md` says `soma run FILE` reads Soma Lisp source. | `test_usage_doc_says_run_file_reads_soma_lisp_source` |
| `docs/usage.md` names `(task ...)` and compatibility `(run ...)` for run requests. | `test_usage_wire_summary_names_task_run_requests` |
| `docs/cli.md` lists `(task ...)` before `(run ...)` and `(ask ...)`. | `test_cli_request_reference_lists_task_before_run` |
| `docs/cli.md` says `soma run FILE` reads Soma Lisp source. | `test_cli_doc_says_run_file_reads_soma_lisp_source` |
| `docs/roadmap.md` marks bounded Soma Lisp v1 with the public task surface built. | `test_roadmap_marks_bounded_soma_lisp_v1_built` |
| The site roadmap mirror marks bounded Soma Lisp v1 with the public task surface built. | `test_site_roadmap_marks_bounded_soma_lisp_v1_built` |
| `docs/lisp-messages.md` lists `(task ...)` in the implemented grammar. | `test_lisp_messages_grammar_lists_task_form` |
| `docs/lisp-messages.md` records bounded Soma Lisp v1 as a built slice. | `test_lisp_messages_records_bounded_soma_lisp_v1_slice` |
| The Chinese overview links the task-form contract. | `test_zh_overview_links_task_form_contract` |
| `AGENTS.md` names the bounded Soma Lisp v1 public task surface. | `test_agents_names_public_task_surface` |

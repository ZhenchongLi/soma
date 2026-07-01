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

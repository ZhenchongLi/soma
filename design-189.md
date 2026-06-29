## Current state

Soma already has the execution substrate this issue needs. `README.md` and
`AGENTS.md` both keep the hard boundary explicit: Lisp source is an edge form,
`soma_lfe:compile/2` validates it into maps, and OTP runtime processes execute
only the canonical step-list data. `soma_run` remains a sequential `gen_statem`
executor that owns run state and starts one `soma_tool_call` worker per tool
invocation.

The current Lisp compiler path is:

1. `soma_lfe:compile/2` calls `soma_lfe_reader:read_forms/1`.
2. `soma_lfe:dispatch/1` routes known single top-level edge forms such as
   `(msg ...)`, `(ask ...)`, `(trace ...)`, `(status ...)`, `(cancel ...)`, and
   `(stop ...)`.
3. Everything else falls through to `soma_lfe_parser:parse_run/1`.

`parse_run/1` currently owns the compatibility/core run surface:

```lisp
(run
  (step s1 echo
    (args (value "hello"))
    (timeout_ms 5000)))
```

It already lowers into `#{run => #{steps => Steps}}`, supports optional
`(detach)`, parses step args into the runtime `args` map, and validates duplicate
step ids plus unknown/forward `from_step` references. Its diagnostic codes are
run-form-specific, for example `duplicate_step_id`, `invalid_from_step`,
`invalid_timeout`, `invalid_step`, and `invalid_top_level_form`.

The reader returns atoms, binaries, integers, and nested lists. Parser
diagnostics conventionally use `line => 0` because line metadata is not carried
through parsed forms. That is acceptable for this issue; the new task diagnostics
should follow the same map shape: `#{code => Code, message => Binary, line => 0}`.

The daemon path already consumes any compile result shaped like
`#{run := #{steps := Steps}}`. `soma_cli_server:handle_lisp_request/4` does not
care whether those steps came from `(run ...)` or another compiler front door.
This means `(task ...)` can be added entirely in `soma_lfe` and documentation,
without changing `soma_runtime`, `soma_actor`, tool execution, event emission, or
the local socket protocol.

The docs still present `(run ...)` / "LFE workflow" as the primary authoring
surface. This issue needs to reposition `(task ...)` as the public static task
form, while retaining `(run ...)` as the compatibility/core form.

## Approach

Add `(task ...)` as a new `soma_lfe:compile/2` dispatch target that lowers to the
existing run map:

```erlang
{ok, #{run => #{steps => Steps}}}
```

No runtime or actor module should import task concepts. The compiler output is
the boundary.

### Public task grammar

Use one public static task shape:

```lisp
(task
  (let* ((read (tool file_read
                 (path "input.txt")
                 (root "/tmp/sandbox")))
         (echoed (tool echo
                   (from read)))
         (write (tool file_write
                  (path "output.txt")
                  (root "/tmp/sandbox")
                  (bytes (from echoed))
                  (timeout-ms 5000))))
    (return write)))
```

Lowering:

```erlang
[
  #{id => read,
    tool => file_read,
    args => #{path => <<"input.txt">>, root => <<"/tmp/sandbox">>}},
  #{id => echoed,
    tool => echo,
    args => #{from_step => read}},
  #{id => write,
    tool => file_write,
    args => #{path => <<"output.txt">>,
              root => <<"/tmp/sandbox">>,
              bytes => {from_step, echoed}},
    timeout_ms => 5000}
]
```

`(return Name)` is a static validation anchor for this slice. It must name an
already-bound binding, but it does not add a runtime step and does not change the
run result shape. The returned compile map remains exactly
`#{run => #{steps => Steps}}`; callers still observe the runtime's normal output
map.

### Compiler integration

In `apps/soma_lfe/src/soma_lfe.erl`:

- Add a dispatch clause for exactly one top-level `(task ...)` form:
  `dispatch([[task | _] = Form]) -> soma_lfe_parser:parse_task(Form);`.
- If multiple top-level forms include a `(task ...)` form, return an
  `invalid_task_form` diagnostic rather than falling into run-form
  `multiple_run_forms`. This keeps malformed task roots task-specific.
- Leave all non-task dispatch behavior unchanged so `(run ...)` remains the
  compatibility/core run form.

In `apps/soma_lfe/src/soma_lfe_parser.erl`:

- Add `parse_task/1`.
- Keep task parsing in the parser module so it can reuse the existing value
  coercion and step validation style without exposing runtime dependencies.
- Share or factor the literal coercion for binary, atom, and integer values.
  Task uses `(from Name)` while compatibility run uses `(from_step Name)`, so the
  from-reference parser should be task-specific.

### Task validation rules

Parse `task` in phases:

1. Validate the root is `(task <single-let-star-form>)`.
2. Validate `let*` is `(let* (<binding> ...) <single-return-form>)`.
3. Parse bindings left to right.
4. For each binding, validate name, tool call, args, timeout, and from
   references against the set of prior binding names.
5. After parsing bindings, validate duplicates.
6. Validate `(return Name)` names an already-bound binding.

Binding shape:

```lisp
(Name (tool ToolName <tool-arg-or-timeout> ...))
```

Rules:

- `Name` must be an atom.
- `Name` must not be a reserved task word.
- `ToolName` must be an atom.
- Each binding becomes one step in source order.
- Binding name becomes `id`.
- Tool name becomes `tool`.
- Literal `(Key Value)` pairs become entries in `args`.
- Literal values use the existing coercions: string -> binary, atom -> atom,
  integer -> integer.
- `(from Name)` as the only tool argument, ignoring `(timeout-ms N)` because it
  is step metadata rather than a tool argument, lowers to
  `#{from_step => Name}`.
- `(Key (from Name))` lowers to `Key => {from_step, Name}`.
- `(timeout-ms N)` lowers to `timeout_ms => N`.
- Timeout values must be positive integers.
- Unknown and forward `(from Name)` references both produce
  `invalid_from_binding`.
- Bare `(from Name)` mixed with literal args produces `invalid_tool_form`.

Reserved task words should be explicit and small:

```erlang
[task, 'let*', tool, from, 'timeout-ms', return, if, cond, loop, recur]
```

The unsupported control heads `if`, `cond`, `loop`, and `recur` should produce
`reserved_form` anywhere they appear as task-language form heads. They must also
fail as binding names with `reserved_form`.

Diagnostic ownership:

- `invalid_task_form`: bad task root, zero/multiple task children, or multiple
  top-level forms involving task.
- `invalid_let_star`: malformed `let*` wrapper or body shape that is not a
  missing/malformed return.
- `invalid_binding`: malformed binding shape or non-atom binding name.
- `duplicate_binding`: duplicate binding names after successful binding-name
  parsing.
- `reserved_form`: reserved binding name or unsupported task control form head.
- `invalid_tool_form`: malformed `(tool ...)`, non-atom tool name, malformed
  tool arg pair, or bare `(from Name)` mixed with literal args.
- `invalid_from_binding`: malformed, unknown, or forward `(from Name)`.
- `invalid_timeout`: non-positive, non-integer, malformed, or duplicate
  `(timeout-ms ...)`.
- `invalid_return`: missing, malformed, or unknown `(return Name)`.

Prefer accumulating diagnostics across bindings when the parser can continue
without guessing. It is still acceptable to stop early for malformed root or
`let*` shapes where there is no reliable binding list to walk.

### CLI and docs behavior

No daemon execution changes are needed. `soma_cli:run/1` already reads a file or
stdin and sends raw Lisp source to the daemon; the daemon already compiles source
through `soma_lfe:compile/2` and runs any returned `#{run => #{steps => Steps}}`.

For this slice, do not add task-level dynamic behavior or control flow. If
`--detach` support for `(task ...)` is desired, it should remain a CLI execution
mode rather than a task-language construct. The minimum compatible path is to
keep existing `(run (detach) ...)` behavior unchanged and not document detached
task source until a follow-up acceptance criterion requires it.

Documentation changes:

- `README.md`: make the primary `soma run FILE` quick-start example use
  `(task ...)`.
- `docs/lfe-dsl.md`: document `(task ...)` as the public static task form and
  `(run ...)` as the compatibility/core run form.
- `docs/lfe-dsl.md`: include this exact sentence:
  `When a need is dynamic, keep the dynamic decision in the actor/planner layer and submit a new bounded static Soma Lisp task for each execution attempt.`
- `docs/design.md`: include this exact boundary statement:
  `Soma Lisp source -> soma_lfe:compile/2 -> validated maps -> OTP execution`
- `docs/cli.md`: describe `soma run FILE` as reading Soma Lisp source.
- `docs/usage.md`: describe `soma run FILE` as reading Soma Lisp source.

## Acceptance criteria → tests

Add focused EUnit coverage in `apps/soma_lfe/test/soma_lfe_task_tests.erl` for
the compiler surface. Use `soma_lfe:compile/2` in all task tests because the
acceptance criteria name the public compiler boundary.

| Acceptance criterion | Test |
| --- | --- |
| A single `(task ...)` top-level form compiles through `soma_lfe:compile/2` to `#{run => #{steps => Steps}}`. | `soma_lfe_task_tests:test_task_compiles_to_run_steps/0` |
| Each `let*` binding becomes one runtime step in binding order. | `soma_lfe_task_tests:test_let_star_bindings_preserve_order/0` |
| A binding name becomes the runtime step `id`. | `soma_lfe_task_tests:test_binding_name_becomes_step_id/0` |
| A `(tool ToolName ...)` call becomes the runtime step `tool`. | `soma_lfe_task_tests:test_tool_call_becomes_step_tool/0` |
| Literal `(Key Value)` task arguments use existing coercions for strings, atoms, integers. | `soma_lfe_task_tests:test_literal_task_args_use_existing_coercions/0` |
| `(from Name)` as the only tool argument lowers to `#{from_step => Name}`. | `soma_lfe_task_tests:test_bare_from_lowers_to_from_step/0` |
| `(Key (from Name))` lowers to `Key => {from_step, Name}`. | `soma_lfe_task_tests:test_field_from_lowers_to_from_step_tuple/0` |
| `(timeout-ms N)` lowers to `timeout_ms => N` on the step map. | `soma_lfe_task_tests:test_timeout_ms_lowers_to_step_timeout_ms/0` |
| `(return Name)` validates that `Name` has already been bound. | `soma_lfe_task_tests:test_return_bound_name_compiles/0` |
| Duplicate binding names fail with `duplicate_binding`. | `soma_lfe_task_tests:test_duplicate_binding_returns_diagnostic/0` |
| Unknown `(from Name)` references fail with `invalid_from_binding`. | `soma_lfe_task_tests:test_unknown_from_binding_returns_diagnostic/0` |
| Forward `(from Name)` references fail with `invalid_from_binding`. | `soma_lfe_task_tests:test_forward_from_binding_returns_diagnostic/0` |
| Missing `(return Name)` bodies fail with `invalid_return`. | `soma_lfe_task_tests:test_missing_return_returns_diagnostic/0` |
| Unknown `(return Name)` references fail with `invalid_return`. | `soma_lfe_task_tests:test_unknown_return_returns_diagnostic/0` |
| Invalid `(timeout-ms N)` values fail with `invalid_timeout`. | `soma_lfe_task_tests:test_invalid_timeout_ms_returns_diagnostic/0` |
| Malformed `(task ...)` roots fail with `invalid_task_form`. | `soma_lfe_task_tests:test_malformed_task_root_returns_diagnostic/0` |
| Malformed `let*` bodies fail with `invalid_let_star`. | `soma_lfe_task_tests:test_malformed_let_star_returns_diagnostic/0` |
| Malformed bindings fail with `invalid_binding`. | `soma_lfe_task_tests:test_malformed_binding_returns_diagnostic/0` |
| Malformed `(tool ...)` calls fail with `invalid_tool_form`. | `soma_lfe_task_tests:test_malformed_tool_form_returns_diagnostic/0` |
| Reserved task words fail as binding names with `reserved_form`. | `soma_lfe_task_tests:test_reserved_binding_name_returns_diagnostic/0` |
| Unsupported task control heads `if`, `cond`, `loop`, `recur` fail with `reserved_form`. | `soma_lfe_task_tests:test_unsupported_task_control_heads_return_diagnostic/0` |

Add or update docs/source-scan tests for the documentation criteria:

| Acceptance criterion | Test |
| --- | --- |
| README quick start uses `(task ...)` as the primary `soma run` example. | Add `apps/soma_lfe/test/soma_lfe_task_doc_tests.erl:test_readme_quick_start_uses_task_example/0`. |
| `docs/lfe-dsl.md` documents `(task ...)` as the public static task form. | `soma_lfe_task_doc_tests:test_lfe_dsl_documents_task_as_public_static_form/0`. |
| `docs/lfe-dsl.md` documents `(run ...)` as the compatibility/core run form. | `soma_lfe_task_doc_tests:test_lfe_dsl_documents_run_as_compatibility_core_form/0`. |
| `docs/lfe-dsl.md` includes the required dynamic-need sentence. | `soma_lfe_task_doc_tests:test_lfe_dsl_includes_dynamic_need_sentence/0`. |
| `docs/design.md` states `Soma Lisp source -> soma_lfe:compile/2 -> validated maps -> OTP execution`. | `soma_lfe_task_doc_tests:test_design_documents_soma_lisp_boundary/0`. |
| `docs/cli.md` describes `soma run FILE` as reading Soma Lisp source. | `soma_lfe_task_doc_tests:test_cli_doc_says_run_file_reads_soma_lisp_source/0`. |
| `docs/usage.md` describes `soma run FILE` as reading Soma Lisp source. | `soma_lfe_task_doc_tests:test_usage_doc_says_run_file_reads_soma_lisp_source/0`. |

Keep existing compatibility tests green:

- `soma_lfe_compile_tests`
- `soma_lfe_validation_tests`
- `soma_lfe_runtime_SUITE`
- `soma_cli_SUITE`
- `soma_cli_server_SUITE`
- `soma_cli_dispatch_SUITE`

The normal gate remains:

```bash
rebar3 eunit && rebar3 ct
```

## Risks & trade-offs

- The task grammar introduces `let*` binding syntax but intentionally does not
  introduce runtime variables. Bindings are only compile-time names for runtime
  step ids. This keeps the runtime sequential and avoids turning `soma_run` into
  a workflow engine.
- `(return Name)` can look like output projection, but this slice only validates
  the returned name. Adding result projection would require a new public result
  contract and is outside the requested `#{run => #{steps => Steps}}` output.
- Reusing the existing reader means task diagnostics will usually use
  `line => 0`. Better source locations can be a later reader/parser refactor;
  this issue should not widen into line metadata plumbing.
- Task-specific diagnostic codes will coexist with compatibility-run diagnostic
  codes. That is intentional: `(run ...)` stays stable while `(task ...)` gets
  the public-language diagnostics named by this issue.
- `timeout-ms` differs from compatibility `timeout_ms`. The public task surface
  should use the hyphenated Lisp form required by the issue and lower to the
  runtime atom `timeout_ms`.
- Keeping `--detach` as existing `(run ...)` behavior avoids adding an
  execution-mode construct to task source. The trade-off is that detached task
  files are not documented in this slice unless a follow-up explicitly defines
  the CLI rewrite and parse behavior for `(task ...)`.
- The parser must reject unsupported control heads early with `reserved_form`.
  This is stricter than treating them as unknown tool args, but it protects the
  public v1 language boundary from accidentally implying branches, loops, or
  recursion.

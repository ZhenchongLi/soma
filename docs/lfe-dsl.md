# Soma Lisp / LFE DSL

Soma accepts a constrained Lisp syntax at its edges. This is the public language
for `soma run` workflow files, actor message bodies, LLM proposal forms, and the
local CLI wire.

The compiler lives in `apps/soma_lfe`. It is compile-only:

```text
Lisp source -> soma_lfe:compile/2 -> validated maps -> runtime / actor / CLI API
```

`soma_lfe:compile/2` starts no processes, emits no runtime events, opens no
network sockets, and has no dependency on `soma_runtime`. If compilation fails,
no run or task is started.

For command usage, see [cli.md](cli.md). For the runtime boundaries this language
feeds, see [design.md](design.md).

## Public static task form

`(task ...)` is the public static task form for bounded Soma Lisp workflows. It
compiles through `soma_lfe:compile/2` into the same validated run-step map shape
that enters the runtime boundary.

`(run ...)` remains the compatibility/core run form. It exposes the canonical
step-list syntax used by the runtime and older callers, while `(task ...)` is
the preferred public static task surface.

When a need is dynamic, keep the dynamic decision in the actor/planner layer and submit a new bounded static Soma Lisp task for each execution attempt.

## Compile API

```erlang
soma_lfe:compile(Source, #{}) ->
    {ok, Map} | {error, [Diagnostic]}.

soma_lfe:compile_file(Path, #{}) ->
    {ok, Map} | {error, [Diagnostic]}.
```

`Source` may be a binary or string. Strings in Lisp source compile to Erlang
binaries; symbols compile to atoms; integers stay integers.

The top-level form selects the result shape:

| Form | Result |
| --- | --- |
| `(task ...)` | `#{run => #{steps => [...]}}` |
| `(run ...)` | `#{run => #{steps => [...]}}` |
| `(msg ...)` | actor message envelope map |
| `(reply ...)`, `(reject ...)`, `(run-steps ...)` | proposal map |
| `(ask ...)` | CLI ask command map |
| `(trace ...)`, `(status ...)`, `(cancel ...)`, `(stop)` | CLI read/manage command map |

## Task Files

`soma run FILE` reads Soma Lisp source. Public static tasks use one `(task ...)`
form:

```lisp
(task
  (let* ((<id> (tool <tool>
                 (<arg-key> <arg-value>)
                 (timeout-ms <positive-integer>))))
    (return <id>)))
```

- Each `let*` binding becomes one runtime step in binding order.
- The binding name becomes the step `id`.
- `(tool ToolName ...)` becomes the step `tool`.
- Literal tool arguments become the step `args`.
- `(from Name)` passes a prior step's whole output as `#{from_step => Name}`.
- `(Key (from Name))` passes a prior step's output into one field.
- `(return Name)` must reference a bound step.

## Compatibility/Core Run Form

`(run ...)` remains the compatibility/core run form for callers that need the
canonical step-list syntax directly.

```lisp
(run
  (step <id> <tool>
    (args <arg-pairs...>)
    (timeout_ms <positive-integer>))
  ...)
```

- `<id>` is a unique symbol within the run.
- `<tool>` names a registered tool. Tool registration is checked by the runtime,
  not by the compiler.
- `(args ...)` is optional; absent args compile to an empty map.
- `(timeout_ms N)` is optional and must be a positive integer.

Detached runs use the same form with a `(detach)` marker. The packaged CLI adds
this marker when you pass `--detach`:

```lisp
(run
  (detach)
  (step slow sleep
    (args (ms 5000))))
```

## Args

Literal key/value pairs:

```lisp
(args
  (path "input.txt")
  (root "/tmp/soma-demo")
  (count 3)
  (mode append))
```

Compile to an Erlang map with atom keys. Strings become binaries.

Use a prior step's whole output as the next step's args:

```lisp
(args (from_step read))
```

Use a prior step's output as one field:

```lisp
(args
  (path "output.txt")
  (bytes (from_step process)))
```

`from_step` may only reference an earlier step in the same run. Unknown or
forward references are compile errors.

## Task Example

```bash
mkdir -p /tmp/soma-demo
printf 'hi soma\n' > /tmp/soma-demo/input.txt

cat > /tmp/soma-demo/pipeline.lfe <<'EOF'
(run
  (step read file_read
    (args (path "input.txt") (root "/tmp/soma-demo")))
  (step process echo
    (args (from_step read)))
  (step write file_write
    (args (path "output.txt") (root "/tmp/soma-demo") (bytes (from_step process)))))
EOF

soma run /tmp/soma-demo/pipeline.lfe
```

The compiled run contains the exact step-list maps accepted by `soma_run`:

```erlang
[
  #{id => read, tool => file_read,
    args => #{path => <<"input.txt">>, root => <<"/tmp/soma-demo">>}},
  #{id => process, tool => echo,
    args => #{from_step => read}},
  #{id => write, tool => file_write,
    args => #{path => <<"output.txt">>, root => <<"/tmp/soma-demo">>,
              bytes => {from_step, process}}}
]
```

## Actor Messages

`(msg ...)` compiles to an actor envelope. It is used at actor and Lisp-edge
boundaries, not by `soma run`.

```lisp
(msg
  (type "task")
  (payload "copy a file")
  (correlation-id "corr-1")
  (steps
    (step
      (id echo-it)
      (tool echo)
      (args (value "hello")))))
```

Required fields:

- `(type VALUE)`
- `(payload VALUE)`

Optional fields:

- `(correlation-id "...")`
- `(steps (step ...))`
- `(llm ...)`

Nested message steps use pair form, not the compact run-workflow form:

```lisp
(step
  (id s1)
  (tool echo)
  (args (value "hi")))
```

## Proposal Forms

Proposal forms are data returned by a planner or model and then normalized,
checked by policy, and executed only if approved.

Reply proposal:

```lisp
(reply (text "done"))
```

Compiles to:

```erlang
#{kind => reply, text => <<"done">>}
```

Reject proposal:

```lisp
(reject (reason "..."))
```

Compiles to a reject-kind proposal:

```erlang
#{kind => reject, reason => <<"...">>}
```

The exact result shape includes `kind => reject`.

Run-steps proposal:

```lisp
(run-steps
  (step
    (id s1)
    (tool echo)
    (args (value "hi"))))
```

Compiles to:

```erlang
#{kind => run_steps,
  steps => [#{id => s1, tool => echo, args => #{value => <<"hi">>}}]}
```

The actor still normalizes the proposal, applies policy and budgets, and starts
an owned `soma_run` only when the proposal is approved.

## CLI Command Forms

The local daemon wire also uses Lisp. `soma` builds these forms for you, but
custom clients can send the same request shapes.

Ask:

```lisp
(ask
  (intent "summarize the build log")
  (allow echo file_read)
  (budget-llm 3)
  (budget-steps 5))
```

Compiles to:

```erlang
#{ask => #{intent => <<"summarize the build log">>,
           tool_policy => #{allowed_tools => [echo, file_read]},
           budget => #{max_llm_calls => 3, max_steps => 5}}}
```

Read/manage commands:

```lisp
(trace "corr-1")
(status "task-1")
(cancel "task-1")
(stop)
```

These compile to maps keyed by `trace`, `status`, `cancel`, or `stop`.

## Diagnostics

Compilation returns `{error, Diagnostics}`. Diagnostics are maps with at least a
`code`, `message`, and `line`.

Common diagnostic codes:

| Code | Trigger |
| --- | --- |
| `missing_run_form` | Empty source where a run form was expected. |
| `multiple_run_forms` | More than one top-level run form. |
| `invalid_top_level_form` | A run source is not headed by `run`. |
| `duplicate_step_id` | Two run steps share an id. |
| `invalid_from_step` | `from_step` points to an unknown or later step. |
| `invalid_timeout` | `timeout_ms` is missing a positive integer. |
| `invalid_step` | A step or arg pair is malformed. |
| `unknown_form` | A child form is not recognized in that context. |
| `missing_required_field` | A message or ask form is missing a required field. |
| `malformed_form` | A CLI command form has the wrong shape. |
| `malformed_proposal` | A proposal form has the wrong shape. |

Errors are accumulated where possible, especially across run steps.

## Non-goals

The DSL is intentionally narrow:

- No arbitrary Lisp evaluation.
- No shell execution.
- No model/provider calls.
- No policy bypass.
- No runtime event emission from the compiler.
- No loops, branches, variables, or DAG scheduling inside `soma_run`.
- No resume policy decisions in the compiler; resume is derived from the event
  trail by the runtime resume modules.

## Proof-to-test Mapping

These tests preserve the compile-only boundary and the runtime behavior of
DSL-sourced runs:

| Property | Test module | Test name |
| --- | --- | --- |
| DSL demo compiles and runs to `run.completed` | `soma_lfe_runtime_SUITE` | `test_dsl_demo_runs_to_completed` |
| Compiled demo produces the normal event trail | `soma_lfe_runtime_SUITE` | `test_dsl_demo_event_trail` |
| Each tool call has a distinct worker pid; DSL does not bypass `soma_tool_call` | `soma_lfe_runtime_SUITE` | `test_dsl_tool_calls_have_distinct_pids` |
| Compiled `fail` step fails the run without killing the session | `soma_lfe_runtime_SUITE` | `test_dsl_fail_step_fails_run_session_survives` |
| Compiled `sleep` step can be timed out by the runtime | `soma_lfe_runtime_SUITE` | `test_dsl_sleep_step_times_out` |
| Compiled `sleep` step can be cancelled by the runtime | `soma_lfe_runtime_SUITE` | `test_dsl_sleep_step_cancels` |
| Session recovers after DSL-sourced failure | `soma_lfe_runtime_SUITE` | `test_dsl_session_recovers_after_failed` |
| Session recovers after DSL-sourced timeout | `soma_lfe_runtime_SUITE` | `test_dsl_session_recovers_after_timeout` |
| Session recovers after DSL-sourced cancellation | `soma_lfe_runtime_SUITE` | `test_dsl_session_recovers_after_cancelled` |
| Duplicate step ids fail compilation | `soma_lfe_validation_tests` | `test_duplicate_step_id_returns_diagnostic` |
| Unknown `from_step` references fail compilation | `soma_lfe_validation_tests` | `test_unknown_from_step_returns_diagnostic` |
| Forward `from_step` references fail compilation | `soma_lfe_validation_tests` | `test_forward_from_step_returns_diagnostic` |
| Invalid `timeout_ms` values fail compilation | `soma_lfe_validation_tests` | `test_invalid_timeout_returns_diagnostic` |
| Unknown DSL forms fail compilation | `soma_lfe_validation_tests` | `test_unknown_form_returns_diagnostic` |
| Compile failure does not start a run and emits no runtime events | `soma_lfe_validation_tests` | `test_invalid_dsl_does_not_start_run` |
| Compiler has no runtime dependency at compile time or runtime | `soma_lfe_tests` | `test_soma_lfe_does_not_depend_on_soma_runtime` |

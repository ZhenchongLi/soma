# LFE DSL

The LFE DSL is a compile-only layer above the Soma runtime. It started as a
small Lisp-flavored syntax that translates into the step-list format
`soma_agent_session:start_run/2` already accepts; it now also parses the Lisp
edge forms used by actors and the local CLI wire. The compiler lives in the
`soma_lfe` OTP application; the runtime (`soma_runtime`) has no dependency on it
— the two applications are deliberately separate.

This DSL is Soma's first **agent intent language**. Its primary design target is
not "make Lisp pleasant for humans"; it is "make operational intent easy for an
agent to generate, validate, repair, diff, and audit." Lisp syntax is useful
because it is a compact tree-shaped surface. The harder and more important work
is deciding which forms Soma exposes.

The language is intentionally constrained. It is closer to a UDF-style extension
surface for a larger engine than to a general-purpose programming language: the
DSL names safe hooks into the Soma runtime; Erlang/OTP supplies the execution
semantics.

## The compile-only contract

```
Lisp source  -->  soma_lfe:compile/2  -->  validated map  -->  caller/runtime boundary
                      (compile layer)                         (runtime layer)
```

`soma_lfe:compile/2` is a pure function that returns either `{ok, Map}` or
`{error, [Diagnostic]}`. It starts no processes, emits no runtime events, and
never touches the supervisor tree. If compilation fails, no run is started and
no events appear in the event store.

The compiler may be fed by a human, an LLM planner, a UI, or another tool. That
does not change the contract: source is parsed and validated into canonical
maps, and only those maps enter the runtime or actor boundary.

## Public static task form

`(task ...)` is the public static task form for bounded Soma Lisp workflows. It
compiles through `soma_lfe:compile/2` into the same validated run-step map shape
that enters the runtime boundary.

`(run ...)` remains the compatibility/core run form. It exposes the canonical
step-list syntax used by the runtime and older callers, while `(task ...)` is
the preferred public static task surface.

## v0.3 run syntax

A valid run workflow contains exactly one top-level `run` form. Inside `run`
there are one or more `step` forms. This remains the form `soma_cli:run/1` sends
over the local socket.

```lisp
(run
  (step <id> <tool>
    (args <arg-pairs...>)
    (timeout_ms <positive-integer>))
  ...)
```

- `<id>` — atom; unique within the run.
- `<tool>` — atom; must name a registered tool at runtime (the compiler does
  not check registration; that is the runtime's job).
- `(args ...)` — keyword-value pairs. See arg forms below.
- `(timeout_ms N)` — optional; positive integer milliseconds. If absent the
  step carries no `timeout_ms` key and the runtime uses its own default.

## Arg forms

Three arg forms are accepted inside `(args ...)`:

**Literal key-value pair**

```lisp
(path "input.txt")
```

Compiles to `path => <<"input.txt">>` (strings become binaries; atoms and
integers are passed through).

**Bare `from_step` reference** — the entire args map becomes a reference to a
prior step's output:

```lisp
(from_step <step-id>)
```

Compiles to `#{from_step => <step-id>}`. Must be the only entry in `(args ...)`.

**Field-level `from_step` reference** — one arg value is a reference to a
prior step's output:

```lisp
(bytes (from_step <step-id>))
```

Compiles to `bytes => {from_step, <step-id>}`. Other args can accompany it.

In both `from_step` forms the referenced `<step-id>` must be a step that
appears earlier in the same `run` form (forward references are rejected at
compile time).

## The `file_read -> echo -> file_write` demo

This is the canonical end-to-end example. It reads a file, passes the bytes
through echo, and writes them to a new path.

DSL source:

```lisp
(run
  (step read file_read
    (args (path "input.txt") (root "/tmp/sandbox")))
  (step process echo
    (args (from_step read)))
  (step write file_write
    (args (path "output.txt") (root "/tmp/sandbox") (bytes (from_step process)))))
```

Compiled steps (what `soma_lfe:compile/2` returns inside `#{run => #{steps => ...}}`):

```erlang
[
  #{id => read,    tool => file_read,
    args => #{path => <<"input.txt">>, root => <<"/tmp/sandbox">>}},
  #{id => process, tool => echo,
    args => #{from_step => read}},
  #{id => write,   tool => file_write,
    args => #{path => <<"output.txt">>, root => <<"/tmp/sandbox">>,
              bytes => {from_step, process}}}
]
```

Passing these steps to `soma_agent_session:start_run/2` runs the three-step
demo through the full runtime: distinct `soma_tool_call` worker processes, the
normal event trail, and the `file_write` tool writing the bytes to disk.

## Calling the compiler

```erlang
Source = <<"(run (step greet echo (args (value \"hello\"))))">>,
{ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
{ok, S} = soma_agent_session:start_link(#{}),
{ok, RunId} = soma_agent_session:start_run(S, Steps).
```

`compile_file/2` reads a file first, then calls `compile/2`:

```erlang
{ok, #{run := #{steps := Steps}}} = soma_lfe:compile_file("/path/to/run.lfe", #{}).
```

## Other edge forms

`soma_lfe:compile/2` also accepts the Lisp forms used outside the sequential run
executor:

| Form | Result shape | Consumer |
|---|---|---|
| `(msg ...)` | `#{type := ..., payload := ..., steps? := ..., llm? := ...}` | `soma_actor:send/2` / `ask/3` string boundary |
| `(reply (text "..."))` | `#{kind => reply, text => ...}` | LLM proposal boundary |
| `(run-steps (step ...))` | `#{kind => run_steps, steps => [...]}` | LLM proposal boundary |
| `(reject (reason "..."))` | `#{kind => reject, reason => ...}` | LLM proposal boundary |
| `(ask (intent "...") ...)` | `#{ask => ...}` | `soma_cli_server` ask handler |
| `(trace "...")`, `(status "...")`, `(cancel "...")` | command maps keyed by `trace`, `status`, or `cancel` | `soma_cli_server` read/manage handlers |

These are still compile-only boundaries. They start no processes and emit no
runtime events by themselves.

## Diagnostic codes

| Code | Trigger |
|------|---------|
| `missing_run_form` | Source is empty (no forms). |
| `multiple_run_forms` | More than one top-level form. |
| `invalid_top_level_form` | Top-level form is not headed by `run`. |
| `duplicate_step_id` | Two or more steps share the same `<id>`. |
| `invalid_from_step` | `from_step` references a step id that does not exist or appears later in the run (forward reference). |
| `invalid_timeout` | `timeout_ms` value is not a positive integer. |
| `unknown_form` | A child form inside `run` or `step` is not recognized. |
| `invalid_step` | A `step` form is missing its `<id>` or `<tool>`, or an arg pair is malformed. |

Errors are accumulated across all steps — a single compile call can return
multiple diagnostics.

## Non-goals

The LFE DSL is intentionally minimal. These items are out of scope for this layer
and must not be added to the compiler:

- **LLM execution or planner integration** — this layer is compiler-only. An LLM
  or agent may author this syntax, but provider calls, repair loops, and policy
  gates live outside this compiler.
- **DAG execution** — steps run in list order; no parallel branches.
- **Loops or branches** — no control flow beyond a flat step list.
- **Variables or bindings** — `from_step` references are the only
  data-threading mechanism.
- **Arbitrary Lisp evaluation** — the reader produces Erlang terms from a
  fixed grammar; it is not a general-purpose Lisp interpreter.
- **Persistent resume** — compiled run steps are passed to `start_run/2` and run
  to a terminal state; there is no checkpoint or resume mechanism.
- **New runtime event semantics** — the compiler emits no events and adds no
  new event types; the runtime event contract is unchanged.

## Proof-to-test mapping

The following table maps each property of the compile-only contract to the
test that proves it. This mapping is the barrier that prevents future v0.4
work from accidentally treating the DSL as a runtime component.

| Property | Test module | Test name |
|----------|-------------|-----------|
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

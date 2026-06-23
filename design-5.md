# [cc] Execution core (happy path): supervision tree, session, run, tool-call

## Current state

The pieces below the runtime exist and are tested, but nothing wires them into a running tree.

The event store (`apps/soma_event_store/src/soma_event_store.erl`) is a `gen_server` started by `start_link/0`. It has `append/2`, `all/1`, `by_run/2`, `by_session/2`. Every appended event is normalized to the eight mandatory keys, and any key the caller leaves out is filled with `undefined`. `event_id` and `timestamp` are auto-filled if absent. Events come back from `all/1` in append order.

The tool registry (`apps/soma_tools/src/soma_tool_registry.erl`) is a plain map module, not a process. `register/3` returns an updated `name => module` map, `lookup/2` reads one back, `names/1` lists the keys. It holds no state of its own.

The five v0.1 tools are written and tested as `soma_tool` behaviour modules: `soma_tool_echo`, `soma_tool_sleep`, `soma_tool_fail`, `soma_tool_file_read`, `soma_tool_file_write`. Their `describe/0` returns metadata under the atom names `echo`, `sleep`, `fail`, `file_read`, `file_write`. `echo:invoke/2` returns its input unchanged. `file_read:invoke/2` matches `#{path := P}` with ctx `#{root := R}` and returns the file bytes. `file_write:invoke/2` matches `#{path := P, bytes := B}` with ctx `#{root := R}` and returns the byte count. Both file tools resolve the path under the root through `soma_tool_file:resolve_under_root/2`, so a ctx without `root` will not match the function head.

What is missing: there is no `soma_app`, no `soma_sup`, no `soma_session_sup`, no `soma_run_sup`, no `soma_agent_session`, no `soma_run`, no `soma_tool_call`. The `soma_runtime` app has only its `.app.src` and declares no `mod` entry, so starting the application boots nothing. There is no code that turns a step list into a sequence of tool calls, builds the ctx each tool sees, or emits the run event trail.

This issue builds the spine for the happy path only. A run with all-succeeding tools runs its steps in order and reaches `completed`, emitting the full event trail. Tool errors, crashes, hangs, timeout enforcement, and cancellation are the next issue and are out of scope here.

## Approach

### Boot the tree from the application

Add `soma_app` as the `soma_runtime` application callback module and point the `.app.src` `mod` at it. `soma_app:start/2` starts `soma_sup`. `soma_sup` is a `one_for_one` supervisor with four children in this order: `soma_event_store`, `soma_tool_registry`, `soma_session_sup`, `soma_run_sup`. Starting the `soma_runtime` application is what the boot criterion checks, so the application must be runnable, not just compilable.

### Make the registry a process

The registry module today is a pure map, but the tree lists `soma_tool_registry` as a supervised child and the runtime has to resolve tools through one shared seeded registry at run time. The smallest move that keeps both true: add a `gen_server` that holds one registry map as its state, seeded at `init/1` with the five v0.1 tools. The existing pure functions `register/3`, `lookup/2`, `names/1` stay as they are. The process wraps them.

This means adding a process API to the same module: `start_link/0` to boot it under the supervisor, and `lookup/2` already takes a registry as its first argument so the process needs a differently-shaped call. I will add `resolve/1` (one argument, the tool name) as the process-facing lookup that calls into the running registry, keeping the pure `lookup/2` untouched for the unit tests that already use it. The seed list maps each atom name to its module: `echo => soma_tool_echo`, `sleep => soma_tool_sleep`, `fail => soma_tool_fail`, `file_read => soma_tool_file_read`, `file_write => soma_tool_file_write`.

The downside is one module now has two shapes (pure map functions and a process). I take that over splitting into two modules because the issue's open question reads "seeded registry the runtime resolves through", and a second module would duplicate the type and the names.

### Session as a long-lived gen_server

`soma_agent_session` is a `gen_server` started under `soma_session_sup` (a `simple_one_for_one` supervisor). Starting a session generates a `session_id`, records `session.started` in the event store, and returns the pid. The session holds `session_id`, a handle to the event store and registry, and a map of runs it has started with their last-known status.

`start_run/2` takes a step list, generates a `run_id`, records `run.accepted`, starts a `soma_run` under `soma_run_sup`, tracks it as active, and returns the `run_id`. The session never touches tool logic. When a run reaches a terminal state it sends `{run_completed, RunId, Result}` back to the session, which updates that run's status to `completed`. `get_status/1` returns the session's view, including each run's status.

The session must stay alive across the run finishing. For the happy path that means the run completing normally does not take the session down. I will not link the session to the run in a way that propagates a normal exit; the session learns the outcome from the `run_completed` message, not from a link signal.

### Run as a gen_statem

`soma_run` is a `gen_statem` started under `soma_run_sup` (a `simple_one_for_one` supervisor). On start it records `run.started`, then drives the step list sequentially. The states follow the README: `accepted -> executing -> waiting_tool -> ... -> completed`. The run owns the step cursor, the accumulated step outputs, and the event emission. It builds the ctx each tool sees.

For each step the run:

1. records `step.started` with that step's `step_id`;
2. resolves the step's args, turning any `from_step` reference into the recorded output of the named prior step;
3. resolves the tool name through the registry to a module;
4. records `tool.started` with a fresh `tool_call_id`;
5. starts a `soma_tool_call` worker under `soma_run_sup` (or as a monitored child), passing the module, the resolved input, and the ctx;
6. waits for the worker's result message before doing anything else;
7. on `{ok, Output}` records `tool.succeeded` then `step.succeeded`, stores the output under the step id, advances the cursor;
8. when the cursor passes the last step, records `run.completed` and tells the session.

Sequential means the run does not start step N+1's worker until step N's worker has reported success. The run is a state machine waiting in `waiting_tool` for one worker at a time, so two tool-call workers never overlap. The test proves this by capturing each worker's pid and asserting they are all distinct and all differ from the run pid.

The ctx the run builds for every tool carries `root` (the sandbox root for this run, supplied in the run request), plus `session_id`, `run_id`, `step_id`, and `tool_call_id`. The file tools need `root`; the ids let a tool tie back to its event trail later.

### The from_step wiring

A step's args may carry `from_step => PriorId`. When the run resolves args it looks up the recorded output of `PriorId` and merges it into the input the tool sees. The README demo wires it so the bytes flow `file_read -> echo -> file_write`:

- `read` runs `file_read` on `#{path => <input>}`, output is the file bytes;
- `echo` has `args => #{from_step => read}`, so its input is the bytes, output is the same bytes;
- `write` has `args => #{path => <output>, from_step => echo}`, so its input is `#{path => <output>, bytes => <bytes>}`.

The shape detail that matters: `echo`'s output is raw bytes, and `file_write` needs them under the `bytes` key. So `from_step` resolution for the write step has to place the prior output under `bytes`, not merge a bare binary. I will define `from_step` resolution as: the referenced step's output becomes the value of a key the consuming step names. For the demo the write step's args read `#{path => <output>, bytes => {from_step, echo}}`, which keeps the rule simple — `{from_step, Id}` anywhere in args is replaced by that step's output. The echo step uses `#{from_step => read}` to mean "the whole input is the prior output". The design supports both: a bare `from_step` key sets the entire input, and a `{from_step, Id}` value sets one field. The mapping test pins this down so Dev implements exactly the shape the demo needs.

### Tool-call worker

`soma_tool_call` is a disposable worker. It is started with the tool module, the resolved input, the ctx, and the pid to report back to. It calls `Module:invoke(Input, Ctx)`, sends the result to the run, and exits. For the happy path it only needs to handle the `{ok, Output}` return. Each invocation is its own process, so each step's invoke runs in a pid distinct from the run and from every other step.

### Events

Every event the run emits goes through `soma_event_store:append/2` carrying the ids it has in hand. Per-step events (`step.started`, `tool.started`, `tool.succeeded`, `step.succeeded`) carry the real `step_id` and `tool_call_id` for that step. Run-level events (`run.started`, `run.completed`) carry `run_id` and `session_id` and leave `step_id`/`tool_call_id` as the store fills them (`undefined`). The session emits `session.started` and `run.accepted`.

The full ordered trail for a successful run is: `session.started`, `run.accepted`, `run.started`, then per step `step.started -> tool.started -> tool.succeeded -> step.succeeded`, then `run.completed`. The trail is read back from the store with `by_run/2` plus `by_session/2` and asserted in order.

## Acceptance criteria → tests

The tests live in a Common Test suite, `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`, because every proof here is about a running supervision tree and process identity, which is what CT is for in this repo's plan. The suite's `init_per_testcase` starts the `soma_runtime` application (which boots the tree) and a sandbox root; `end_per_testcase` stops the application. Tests assert process survival with `is_process_alive/1`, not only return values, following the event store suite's pattern.

### Criterion 1 — application boots the tree with four live children
- Call chain: `application:ensure_all_started(soma_runtime)` -> `soma_app:start/2` -> `soma_sup:start_link/0` -> `soma_sup:init/1` starts the four children
- Test entry: `application:ensure_all_started/1` (the real boot path, no layer bypassed)
- Test: `test_sup_has_four_live_children` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 2 — runtime registry seeded with the five v0.1 tools
- Call chain: `soma_sup:init/1` starts `soma_tool_registry` -> `soma_tool_registry:init/1` seeds the map -> `soma_tool_registry:resolve/1` returns each module
- Test entry: `soma_tool_registry:resolve/1` against the registry the booted tree owns (no layer bypassed)
- Test: `test_registry_seeded_with_v01_tools` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 3 — starting a session returns a live process holding a session_id
- Call chain: `soma_agent_session:start_link/1` (under `soma_session_sup`) -> `soma_agent_session:init/1` assigns `session_id` -> `get_status/1` reports it
- Test entry: `soma_agent_session:start_link/1` then `get_status/1` (the API a real caller uses)
- Test: `test_session_starts_and_holds_id` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 4 — session.started recorded when a session starts
- Call chain: `soma_agent_session:start_link/1` -> `soma_agent_session:init/1` -> `soma_event_store:append/2` with `session.started`
- Test entry: start a session, then read the store with `by_session/2` (the trail a real auditor reads)
- Test: `test_session_started_event_recorded` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 5 — submitting a run returns a run_id and starts a soma_run under soma_run_sup
- Call chain: `soma_agent_session:start_run/2` -> generates `run_id` -> `soma_run_sup:start_run/.. ` -> `soma_run:start_link/..` registers under the run supervisor
- Test entry: `soma_agent_session:start_run/2`, then check `soma_run_sup` children for the run pid (no layer bypassed)
- Test: `test_start_run_returns_id_and_spawns_run` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 6 — run.accepted recorded when a run is accepted
- Call chain: `soma_agent_session:start_run/2` -> `soma_event_store:append/2` with `run.accepted`
- Test entry: `soma_agent_session:start_run/2`, then read the store with `by_run/2`
- Test: `test_run_accepted_event_recorded` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 7 — multi-step run executes strictly sequentially and reaches completed
- Call chain: `soma_agent_session:start_run/2` -> `soma_run` drives step 1's `soma_tool_call`, waits for its result, then drives step 2's worker -> ... -> run reaches `completed`
- Test entry: `soma_agent_session:start_run/2` with a multi-step list; wait for the `run_completed` message, then assert order from the event trail (no layer bypassed)
- Test: `test_multi_step_runs_sequentially_to_completed` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 8 — each step's tool call has its own distinct process
- Call chain: `soma_run` -> per step `soma_tool_call:start_link/..` spawns a worker -> worker reports its result with its own pid -> run records it
- Test entry: run a multi-step list; collect each worker pid from the events or a probe and assert all are distinct from each other and from the run pid
- Test: `test_each_tool_call_has_distinct_pid` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 9 — event store holds the full ordered trail after a successful run
- Call chain: `soma_agent_session:start_run/2` -> session and run append events through `soma_event_store:append/2` -> trail read back with `by_run/2` and `by_session/2`
- Test entry: run the demo step list, then read the ordered event types from the store
- Test: `test_event_trail_in_order` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 10 — every per-step event carries the real step_id and tool_call_id
- Call chain: `soma_run` records `step.started`/`tool.started`/`tool.succeeded`/`step.succeeded` -> each `soma_event_store:append/2` carries that step's `step_id` and `tool_call_id`
- Test entry: run a multi-step list, read per-step events from the store, assert no `undefined` ids on them
- Test: `test_per_step_events_carry_real_ids` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 11 — a from_step arg resolves to the prior step's recorded output
- Call chain: `soma_run` records step N's output -> step N+1 arg resolution replaces its `from_step` reference with that output -> `soma_tool_call` invokes the tool on the resolved input
- Test entry: `soma_agent_session:start_run/2` with a two-step list where step 2 references step 1; assert step 2's output reflects step 1's output (no layer bypassed)
- Test: `test_from_step_resolves_to_prior_output` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 12 — the README demo runs end to end
- Call chain: `soma_agent_session:start_run/2` with `file_read -> echo -> file_write` -> run drives all three workers sequentially -> output file written under the sandbox root -> run reaches `completed`
- Test entry: `soma_agent_session:start_run/2` with the demo step list; after the `run_completed` message, read the output file and compare bytes (the full demo path, no layer bypassed)
- Test: `test_demo_file_read_echo_file_write` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

### Criterion 13 — session stays alive after the run and reports it completed
- Call chain: run reaches `completed` -> sends `{run_completed, RunId, Result}` to `soma_agent_session` -> session updates status -> `get_status/1` reports the run as completed
- Test entry: run a step list to completion, then `is_process_alive/1` on the session pid and `get_status/1` for the run's status
- Test: `test_session_alive_and_reports_completed` in `apps/soma_runtime/test/soma_run_happy_path_SUITE.erl`

## Risks & trade-offs

The registry becoming a process while keeping its pure map functions leaves one module with two personalities. The unit tests in `soma_tool_registry_tests` keep calling the pure `lookup/2` with a map argument, and the runtime calls the new `resolve/1` against the running process. If a future reader assumes the whole module is pure, the `gen_server` callbacks will surprise them. The alternative (a separate `soma_tool_registry_server`) duplicates the seed list and the type, so I keep it in one module and rely on the doc comment to mark the split.

The `from_step` resolution carries two shapes: a bare `from_step` key that sets the whole input, and a `{from_step, Id}` value that sets one field. Two shapes is more surface than one, but the demo needs both — echo wants the whole prior output, file_write wants it under `bytes` alongside a literal `path`. Collapsing to one shape would force the demo step list into an awkward form. The mapping test pins the exact shape so Dev does not have to guess.

This issue wires the run-timeout timer and the worker monitor but does not prove they end a run — those proofs are the next issue. The risk is writing dead plumbing here that the next issue reshapes. I keep the timer and monitor minimal: enough that the happy path's worker-done message is handled through a monitor, so the next issue extends rather than rewrites.

The tests are Common Test, while everything merged so far is EUnit. This is deliberate — these are process-tree and supervision proofs, which the README assigns to CT (`rebar3 ct`). The cost is the suite needs `init_per_testcase`/`end_per_testcase` application start/stop scaffolding that the EUnit modules did not. If the team would rather keep one test framework, these could be EUnit fixtures instead, but CT is the better fit for boot-and-survive proofs.

### Claude

## Verdict
approve

## Real issues
None.

## Questions

- The kill targets the OS pid the port reports — the `/bin/sh` wrapper. The wrapper's `sleep` child reparents to init and keeps counting. I confirmed this: kill the `sh` pid, `ps` shows `sleep 2` with ppid 1, still alive. The marker stays absent only because the `touch` lives in the killed shell. So criteria 2 and 4 prove "the shell that would write the marker is dead," not "every descendant is dead." The design already calls this out (grandchild leak, process-group kill out of scope). Fine for v0.1's one-shot `run a program, take stdout` adapter. Worth a line in the v0.2 follow-up that real CLI tools forking detached children need a process-group kill.

- I verified the marker proof actually discriminates. Killed worker without the OS-pid kill: marker appears (`true`) — the port closing does not reap the child on this BEAM. Worker kill plus `kill -KILL OsPid`: marker absent (`false`). So the new `kill_os_process/1` is load-bearing, not decoration. Good.

## Nits

- Two new dialyzer warnings, both "value produced but unmatched": `soma_run.erl:258` (`os:cmd/1` returns a string the code drops) and `soma_tool_call.erl:52` (the `case` returns the `ReplyTo ! msg` result, unmatched). Not in the merge gate, no user-visible effect. Bind to `_ = os:cmd(...)` and `_ = case ...` to keep `rebar3 dialyzer` clean.

- `waiting_tool/3` os-pid clause binds `_WorkerPid` and never uses it. The real guard is `tool_call_id`. The pid arg carries no weight here; drop it from the message or keep it only if a later check wants worker-pid agreement.

## Functional evidence
- Criterion 1 — pass: `test_cli_overrun_reaches_timeout` (soma_cli_lifecycle_SUITE) — helper sleeps 5s, step budget 100ms, asserts `run.timeout` present and `run.completed` absent in the run trail. CT green.
- Criterion 2 — pass: `test_cli_external_process_dead_after_timeout` — helper `sleep 2; touch $marker`, run driven to `run.timeout`, waits 3s past the sleep window, asserts `filelib:is_file(Marker)` is `false`. I reproduced the discriminator outside CT: worker-kill-only leaves the marker present (`true`); worker-kill plus `kill -KILL OsPid` leaves it absent (`false`).
- Criterion 3 — pass: `test_cli_cancel_reaches_cancelled` — 60s step budget so only `{cancel_run, RunId}` ends the step; waits for `tool.started`, cancels through the session interface, asserts `run.cancelled` present and `run.completed` absent. CT green.
- Criterion 4 — pass: `test_cli_external_process_dead_after_cancel` — marker helper cancelled mid-sleep via `{cancel_run, RunId}`, waits 3s past the sleep window, asserts marker absent. Same discriminator as criterion 2.
- Criterion 5 — pass: `test_session_alive_runs_new_cli_run_after_timeout` and `test_session_alive_runs_new_cli_run_after_cancel` — after the first run hits its terminal state, asserts `is_process_alive(SessionPid)` and a second `cli` run on the same session reaches `run.completed`. Both CT green.
- Criterion 6 — pass: `rebar3 eunit` → 48 tests, 0 failures; `rebar3 ct` → all 44 tests passed, including the pre-existing soma_run_failure_SUITE, soma_run_happy_path_SUITE, and soma_cli_adapter_SUITE.

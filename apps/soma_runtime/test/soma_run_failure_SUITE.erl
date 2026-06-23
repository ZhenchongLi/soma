-module(soma_run_failure_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_error_return_reaches_failed_not_completed/1]).
-export([test_error_trail_tool_step_run_failed_in_order/1]).
-export([test_tool_crash_reaches_failed/1]).
-export([test_session_alive_after_tool_crash/1]).
-export([test_overrun_reaches_timeout_records_run_timeout/1]).
-export([test_hung_worker_dead_after_timeout/1]).
-export([test_cancel_run_reaches_cancelled_records_event/1]).
-export([test_worker_dead_after_cancel/1]).
-export([test_session_alive_after_cancel/1]).
-export([test_session_runs_new_run_after_failed/1]).
-export([test_session_runs_new_run_after_timeout/1]).
-export([test_session_runs_new_run_after_cancelled/1]).
-export([test_failure_events_carry_eight_mandatory_fields/1]).
-export([test_get_status_reports_terminal_outcome/1]).

all() ->
    [test_error_return_reaches_failed_not_completed,
     test_error_trail_tool_step_run_failed_in_order,
     test_tool_crash_reaches_failed,
     test_session_alive_after_tool_crash,
     test_overrun_reaches_timeout_records_run_timeout,
     test_hung_worker_dead_after_timeout,
     test_cancel_run_reaches_cancelled_records_event,
     test_worker_dead_after_cancel,
     test_session_alive_after_cancel,
     test_session_runs_new_run_after_failed,
     test_session_runs_new_run_after_timeout,
     test_session_runs_new_run_after_cancelled,
     test_failure_events_carry_eight_mandatory_fields,
     test_get_status_reports_terminal_outcome].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: a run whose step's tool returns `{error, Reason}' reaches the
%% terminal state `failed' and never reaches `completed'. Driven through the
%% real session/run/tool-call layers: the session starts a run of one `fail'
%% step in error mode; the run's `fail' tool returns `{error, Reason}', and the
%% run records `run.failed' and surfaces `failed' through get_status/1, while
%% `run.completed' never appears in the trail.
test_error_return_reaches_failed_not_completed(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => fail,
               args => #{mode => error, reason => boom}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% the run records run.failed and never run.completed
    true = lists:member(<<"run.failed">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    %% and the session reports the run as failed, never completed
    ok = wait_for_run_status(SessionPid, RunId, failed, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    failed = maps:get(RunId, Runs),
    ok.

%% Criterion 2: the errored run records the failure trail in order:
%% `tool.failed', then `step.failed', then `run.failed'. Driven through the
%% real session/run/tool-call layers; the test reads the run-scoped trail with
%% soma_event_store:by_run/2 and checks the three event indices ascend in that
%% order.
test_error_trail_tool_step_run_failed_in_order(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => fail,
               args => #{mode => error, reason => boom}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    ToolIdx = index_of(<<"tool.failed">>, Types),
    StepIdx = index_of(<<"step.failed">>, Types),
    RunIdx = index_of(<<"run.failed">>, Types),
    true = ToolIdx < StepIdx,
    true = StepIdx < RunIdx,
    ok.

%% Criterion 3: a run whose tool-call process crashes (the tool raises) reaches
%% the terminal state `failed'. Driven through the real session/run/tool-call
%% layers: the session starts a run of one `fail' step in crash mode; the
%% tool-call worker raises and dies, and the run's monitor delivers the `'DOWN''
%% that drives it to `failed'. The crash is observed through the monitor the run
%% holds, not staged by the test. The run records `run.failed' and surfaces
%% `failed' through get_status/1, while `run.completed' never appears.
test_tool_crash_reaches_failed(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => fail,
               args => #{mode => crash, reason => boom}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.failed">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    ok = wait_for_run_status(SessionPid, RunId, failed, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    failed = maps:get(RunId, Runs),
    ok.

%% Criterion 4: the `soma_agent_session' process survives a run whose tool-call
%% process crashes. Driven through the real session/run/tool-call layers: the
%% session starts a run of one `fail' step in crash mode; the tool-call worker
%% raises and dies, the run's monitor drives it to `failed', and the session —
%% which never linked to the run — is still alive afterward. Crash isolation is
%% the whole point: a tool blowing up is data for the run, not a crash of the
%% session.
test_session_alive_after_tool_crash(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => fail,
               args => #{mode => crash, reason => boom}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 50),
    %% the run has reached its terminal `failed' state; the session that owns it
    %% must have survived the tool-call crash
    true = is_process_alive(SessionPid),
    ok.

%% Criterion 5: a run whose tool runs longer than the step's `timeout_ms'
%% reaches the terminal state `timeout' and records `run.timeout'. Driven
%% through the real session/run/tool-call layers: the session starts a run of
%% one `sleep' step whose `ms' is larger than the step's `timeout_ms', so the
%% per-step timer wins the race against the reply. The run records `run.timeout'
%% and never `run.completed'.
test_overrun_reaches_timeout_records_run_timeout(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => sleep,
               args => #{ms => 1000}, timeout_ms => 50}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.timeout">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% the run records run.timeout and never run.completed
    true = lists:member(<<"run.timeout">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    ok.

%% Criterion 6: after the run times out, the hung tool-call worker process is no
%% longer alive. Driven through the real session/run/tool-call layers: the
%% session starts a run of one `sleep' step whose `ms' is larger than the step's
%% `timeout_ms', so the per-step timer wins. The run kills the active worker on
%% `step_timeout'. The test reads the worker pid from the `tool.started' event
%% for that run, waits for `run.timeout', then asserts the worker is gone.
test_hung_worker_dead_after_timeout(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => sleep,
               args => #{ms => 1000}, timeout_ms => 50}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    %% the worker pid travels on the run's `tool.started' event
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 50),
    WorkerPid = tool_call_pid_from(StorePid, RunId, <<"tool.started">>),
    true = is_pid(WorkerPid),
    ok = wait_for_event(StorePid, RunId, <<"run.timeout">>, 50),
    %% the timeout killed the hung worker; it must no longer be alive
    false = is_process_alive(WorkerPid),
    ok.

%% Criterion 7: sending `{cancel_run, RunId}' to the session drives that run to
%% the terminal state `cancelled' and records `run.cancelled'. Driven through
%% the real session/run/tool-call layers: the session starts a run of one slow
%% `sleep' step; while the run waits on that worker the test sends the cancel
%% message to the session's message interface (`SessionPid ! {cancel_run,
%% RunId}'), the real cancel path the README names. The session forwards a
%% `cancel' to the run, which records `run.cancelled' and never `run.completed'.
test_cancel_run_reaches_cancelled_records_event(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => sleep, args => #{ms => 5000}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    %% wait until the run is actually waiting on the worker before cancelling, so
    %% the cancel lands in `waiting_tool', not before the step has started
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 50),
    SessionPid ! {cancel_run, RunId},
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% the run records run.cancelled and never run.completed
    true = lists:member(<<"run.cancelled">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    ok.

%% Criterion 8: after the run is cancelled, the active tool-call worker process
%% is no longer alive. Driven through the real session/run/tool-call layers: the
%% session starts a run of one slow `sleep' step; while the run waits on that
%% worker the test sends `{cancel_run, RunId}' to the session, the real cancel
%% path. The run's cancel clause kills the active worker. The test reads the
%% worker pid from the run's `tool.started' event, waits for `run.cancelled',
%% then asserts the worker is gone.
test_worker_dead_after_cancel(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => sleep, args => #{ms => 5000}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    %% the worker pid travels on the run's `tool.started' event
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 50),
    WorkerPid = tool_call_pid_from(StorePid, RunId, <<"tool.started">>),
    true = is_pid(WorkerPid),
    SessionPid ! {cancel_run, RunId},
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 50),
    %% the cancel killed the active worker; it must no longer be alive
    false = is_process_alive(WorkerPid),
    ok.

%% Criterion 9: the `soma_agent_session' process survives a run that is
%% cancelled. Driven through the real session/run/tool-call layers: the session
%% starts a run of one slow `sleep' step; while the run waits on that worker the
%% test sends `{cancel_run, RunId}' to the session, the real cancel path. The
%% run reaches `cancelled', and the session — which never linked to the run — is
%% still alive afterward. The session must survive cancelled runs just as it
%% survives failed and timed-out ones.
test_session_alive_after_cancel(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => sleep, args => #{ms => 5000}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    %% wait until the run is actually waiting on the worker before cancelling
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 50),
    SessionPid ! {cancel_run, RunId},
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 50),
    %% the run has reached `cancelled'; the session that owns it must have
    %% survived the cancel
    true = is_process_alive(SessionPid),
    ok.

%% Criterion 10: after a run that ended `failed', the same session accepts and
%% runs a new run that reaches `completed'. Driven through the real
%% session/run/tool-call layers: the session first runs a `fail' step in error
%% mode (run ends `failed'), then -- on the same session -- runs a plain echo
%% step list that reaches `completed' through the normal happy path. The session
%% never linked to the failed run, so it is untouched and the second run starts
%% under soma_run_sup like any other.
test_session_runs_new_run_after_failed(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% first run: a `fail' step that ends the run `failed'
    BadSteps = [#{id => s1, tool => fail,
                  args => #{mode => error, reason => boom}}],
    {ok, BadRunId} = soma_agent_session:start_run(SessionPid, BadSteps),
    ok = wait_for_event(StorePid, BadRunId, <<"run.failed">>, 50),
    %% second run on the same session: a plain echo step list
    GoodSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    {ok, GoodRunId} = soma_agent_session:start_run(SessionPid, GoodSteps),
    ok = wait_for_event(StorePid, GoodRunId, <<"run.completed">>, 50),
    %% the new run reaches `completed' and the session reports it as such
    ok = wait_for_run_status(SessionPid, GoodRunId, completed, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    completed = maps:get(GoodRunId, Runs),
    ok.

%% Criterion 10: after a run that ended `timeout', the same session accepts and
%% runs a new run that reaches `completed'. The first run is a `sleep' step that
%% overruns its `timeout_ms' (run ends `timeout'); the second run -- on the same
%% session -- is a plain echo step list that reaches `completed'.
test_session_runs_new_run_after_timeout(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% first run: a `sleep' step that overruns its budget and ends `timeout'
    BadSteps = [#{id => s1, tool => sleep,
                  args => #{ms => 1000}, timeout_ms => 50}],
    {ok, BadRunId} = soma_agent_session:start_run(SessionPid, BadSteps),
    ok = wait_for_event(StorePid, BadRunId, <<"run.timeout">>, 50),
    %% second run on the same session: a plain echo step list
    GoodSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    {ok, GoodRunId} = soma_agent_session:start_run(SessionPid, GoodSteps),
    ok = wait_for_event(StorePid, GoodRunId, <<"run.completed">>, 50),
    %% the new run reaches `completed' and the session reports it as such
    ok = wait_for_run_status(SessionPid, GoodRunId, completed, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    completed = maps:get(GoodRunId, Runs),
    ok.

%% Criterion 10: after a run that ended `cancelled', the same session accepts and
%% runs a new run that reaches `completed'. The first run is a slow `sleep' step
%% cancelled mid-flight through `{cancel_run, RunId}' (run ends `cancelled'); the
%% second run -- on the same session -- is a plain echo step list that reaches
%% `completed'.
test_session_runs_new_run_after_cancelled(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% first run: a slow `sleep' step cancelled mid-flight
    BadSteps = [#{id => s1, tool => sleep, args => #{ms => 5000}}],
    {ok, BadRunId} = soma_agent_session:start_run(SessionPid, BadSteps),
    ok = wait_for_event(StorePid, BadRunId, <<"tool.started">>, 50),
    SessionPid ! {cancel_run, BadRunId},
    ok = wait_for_event(StorePid, BadRunId, <<"run.cancelled">>, 50),
    %% second run on the same session: a plain echo step list
    GoodSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    {ok, GoodRunId} = soma_agent_session:start_run(SessionPid, GoodSteps),
    ok = wait_for_event(StorePid, GoodRunId, <<"run.completed">>, 50),
    %% the new run reaches `completed' and the session reports it as such
    ok = wait_for_run_status(SessionPid, GoodRunId, completed, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    completed = maps:get(GoodRunId, Runs),
    ok.

%% Criterion 11: each of the five failure events -- `tool.failed',
%% `step.failed', `run.failed', `run.cancelled', `run.timeout' -- carries all
%% eight mandatory event fields (`event_id', `timestamp', `session_id',
%% `run_id', `step_id', `tool_call_id', `event_type', `payload'). Driven through
%% the real session/run/tool-call layers: one run errors (emitting
%% `tool.failed'/`step.failed'/`run.failed'), one run is cancelled (emitting
%% `run.cancelled'), one run overruns (emitting `run.timeout'). The test reads
%% each event back with soma_event_store:by_run/2 and asserts every one of the
%% eight keys is present (key exists), not that it is non-`undefined' -- the
%% store defaults unset keys to `undefined' and not every field applies to
%% every event.
test_failure_events_carry_eight_mandatory_fields(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% error run: tool.failed, step.failed, run.failed
    ErrSteps = [#{id => s1, tool => fail,
                  args => #{mode => error, reason => boom}}],
    {ok, ErrRunId} = soma_agent_session:start_run(SessionPid, ErrSteps),
    ok = wait_for_event(StorePid, ErrRunId, <<"run.failed">>, 50),
    %% cancelled run: run.cancelled
    CancelSteps = [#{id => s1, tool => sleep, args => #{ms => 5000}}],
    {ok, CancelRunId} = soma_agent_session:start_run(SessionPid, CancelSteps),
    ok = wait_for_event(StorePid, CancelRunId, <<"tool.started">>, 50),
    SessionPid ! {cancel_run, CancelRunId},
    ok = wait_for_event(StorePid, CancelRunId, <<"run.cancelled">>, 50),
    %% timed-out run: run.timeout
    TimeoutSteps = [#{id => s1, tool => sleep,
                      args => #{ms => 1000}, timeout_ms => 50}],
    {ok, TimeoutRunId} = soma_agent_session:start_run(SessionPid, TimeoutSteps),
    ok = wait_for_event(StorePid, TimeoutRunId, <<"run.timeout">>, 50),
    MandatoryKeys = [event_id, timestamp, session_id, run_id, step_id,
                     tool_call_id, event_type, payload],
    Targets = [{ErrRunId, <<"tool.failed">>},
               {ErrRunId, <<"step.failed">>},
               {ErrRunId, <<"run.failed">>},
               {CancelRunId, <<"run.cancelled">>},
               {TimeoutRunId, <<"run.timeout">>}],
    lists:foreach(
      fun({RunId, Type}) ->
              Event = event_of_type(StorePid, RunId, Type),
              [true = maps:is_key(K, Event) || K <- MandatoryKeys]
      end,
      Targets),
    ok.

%% Criterion 12: `get_status/1' reports a non-completed run with its terminal
%% outcome (`failed', `timeout', or `cancelled'), not `completed'. Driven
%% through the real session/run/tool-call layers: three runs on one session each
%% reach a distinct terminal outcome, and after each run reports back the test
%% polls `get_status/1' and asserts the run shows its terminal outcome and never
%% `completed'.
test_get_status_reports_terminal_outcome(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% errored run -> failed
    ErrSteps = [#{id => s1, tool => fail,
                  args => #{mode => error, reason => boom}}],
    {ok, FailedRunId} = soma_agent_session:start_run(SessionPid, ErrSteps),
    ok = wait_for_event(StorePid, FailedRunId, <<"run.failed">>, 50),
    ok = wait_for_run_status(SessionPid, FailedRunId, failed, 50),
    %% overrun run -> timeout
    TimeoutSteps = [#{id => s1, tool => sleep,
                      args => #{ms => 1000}, timeout_ms => 50}],
    {ok, TimeoutRunId} = soma_agent_session:start_run(SessionPid, TimeoutSteps),
    ok = wait_for_event(StorePid, TimeoutRunId, <<"run.timeout">>, 50),
    ok = wait_for_run_status(SessionPid, TimeoutRunId, timeout, 50),
    %% cancelled run -> cancelled
    CancelSteps = [#{id => s1, tool => sleep, args => #{ms => 5000}}],
    {ok, CancelRunId} = soma_agent_session:start_run(SessionPid, CancelSteps),
    ok = wait_for_event(StorePid, CancelRunId, <<"tool.started">>, 50),
    SessionPid ! {cancel_run, CancelRunId},
    ok = wait_for_event(StorePid, CancelRunId, <<"run.cancelled">>, 50),
    ok = wait_for_run_status(SessionPid, CancelRunId, cancelled, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    %% each non-completed run reports its terminal outcome, never `completed'
    failed = maps:get(FailedRunId, Runs),
    timeout = maps:get(TimeoutRunId, Runs),
    cancelled = maps:get(CancelRunId, Runs),
    ok.

%% Read the first event of Type for RunId.
event_of_type(StorePid, RunId, Type) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    [Event | _] = [E || E <- Events, maps:get(event_type, E) =:= Type],
    Event.

%% Read the `tool_call_pid' carried on the first event of Type for RunId.
tool_call_pid_from(StorePid, RunId, Type) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    [Event | _] = [E || E <- Events, maps:get(event_type, E) =:= Type],
    maps:get(tool_call_pid, Event).

%% 1-based index of the first occurrence of Elem in List.
index_of(Elem, List) ->
    index_of(Elem, List, 1).

index_of(Elem, [Elem | _], Idx) ->
    Idx;
index_of(Elem, [_ | Rest], Idx) ->
    index_of(Elem, Rest, Idx + 1).

%% Poll the run-scoped trail until the given event type appears.
wait_for_event(_StorePid, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_event(StorePid, RunId, Type, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(Type, Types) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_event(StorePid, RunId, Type, N - 1)
    end.

%% Poll the session's get_status/1 until it reports RunId at the expected status.
wait_for_run_status(_SessionPid, _RunId, _Expected, 0) ->
    {error, timeout};
wait_for_run_status(SessionPid, RunId, Expected, N) ->
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status, #{}),
    case maps:get(RunId, Runs, undefined) of
        Expected -> ok;
        _ ->
            timer:sleep(20),
            wait_for_run_status(SessionPid, RunId, Expected, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

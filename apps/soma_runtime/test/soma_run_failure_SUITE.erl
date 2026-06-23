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

all() ->
    [test_error_return_reaches_failed_not_completed,
     test_error_trail_tool_step_run_failed_in_order,
     test_tool_crash_reaches_failed,
     test_session_alive_after_tool_crash,
     test_overrun_reaches_timeout_records_run_timeout,
     test_hung_worker_dead_after_timeout,
     test_cancel_run_reaches_cancelled_records_event,
     test_worker_dead_after_cancel,
     test_session_alive_after_cancel].

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

-module(soma_run_failure_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_error_return_reaches_failed_not_completed/1]).
-export([test_error_trail_tool_step_run_failed_in_order/1]).
-export([test_tool_crash_reaches_failed/1]).

all() ->
    [test_error_return_reaches_failed_not_completed,
     test_error_trail_tool_step_run_failed_in_order,
     test_tool_crash_reaches_failed].

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

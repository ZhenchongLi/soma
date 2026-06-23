-module(soma_cli_lifecycle_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_cli_overrun_reaches_timeout/1]).

all() ->
    [test_cli_overrun_reaches_timeout].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: a run whose `cli' step runs longer than the step's `timeout_ms'
%% reaches the terminal `timeout' state. Driven through the real
%% session/run/tool-call layers: the session starts a run of one `cli' step
%% whose external helper sleeps far longer than the step's `timeout_ms', so the
%% per-step timer armed inside `soma_run' wins the race against the worker's
%% reply. The worker sits in `collect_cli/2' reading the port the whole time, so
%% nothing replies before the timer fires. The run records `run.timeout' and
%% never `run.completed', proving the per-step timeout drives a `cli' step to the
%% `timeout' terminal state the same way it drives an in-BEAM step.
test_cli_overrun_reaches_timeout(_Config) ->
    Helper = write_sleep_helper(),
    StorePid = event_store_pid(),
    Manifest = #{name => cli_sleep,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% the step's helper sleeps 5s; the step budget is 100ms, so the per-step
    %% timer must win and drive the run to `timeout'.
    Steps = [#{id => s1, tool => cli_sleep,
               args => #{input => <<"ignored">>}, timeout_ms => 100}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.timeout">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% the run records run.timeout and never run.completed
    true = lists:member(<<"run.timeout">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    ok.

%% Write a tiny cli helper that sleeps far longer than any step budget, then
%% exits 0. It never replies in time, so the per-step timer is what ends the
%% step. It ignores argv and never reads stdin, matching the cli adapter's argv
%% input protocol.
write_sleep_helper() ->
    Base = filename:basedir(user_cache, "soma_cli_lifecycle_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "sleep.sh"),
    Script = <<"#!/bin/sh\n"
               "sleep 5\n">>,
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

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

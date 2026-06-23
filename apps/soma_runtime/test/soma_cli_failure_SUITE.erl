-module(soma_cli_failure_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_missing_executable_named_error/1]).
-export([test_missing_executable_reaches_run_failed_trail/1]).
-export([test_non_executable_permission_error/1]).
-export([test_non_zero_exit_carries_status/1]).

all() ->
    [test_missing_executable_named_error,
     test_missing_executable_reaches_run_failed_trail,
     test_non_executable_permission_error,
     test_non_zero_exit_carries_status].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: when the manifest's `executable' points at a non-existent path,
%% the cli adapter catches the port-open failure and the worker returns a named
%% `{error, {cli_executable_not_found, _}}' instead of dying with a raw port
%% exception. Driven through the full session/run/tool-call stack via
%% soma_agent_session:start_run/2. The proof is that the step's `tool.failed'
%% event carries `payload.reason' matching `{cli_executable_not_found, _}' -- a
%% named reason the worker can only have produced by returning `{error, _}'
%% rather than crashing (a crash would surface the raw exception term through
%% the monitor's `'DOWN'' path instead).
test_missing_executable_named_error(_Config) ->
    StorePid = event_store_pid(),
    Missing = missing_executable_path(),
    false = filelib:is_file(Missing),
    Manifest = #{name => cli_missing,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Missing,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cli_missing, args => #{input => <<"hello">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"tool.failed">>, 50),
    FailEvent = event_of_type(StorePid, RunId, <<"tool.failed">>),
    Payload = maps:get(payload, FailEvent),
    Reason = maps:get(reason, Payload),
    %% the worker returned a named missing-executable error, not a raw port
    %% exception
    {cli_executable_not_found, _} = Reason,
    ok.

%% Criterion 2: a run whose `cli' step targets a missing executable records the
%% failure trail in order: `tool.failed', then `step.failed', then `run.failed'.
%% Driven through the full session/run/tool-call stack via
%% soma_agent_session:start_run/2. The worker's `{error,
%% {cli_executable_not_found, _}}' reply lands in `soma_run' `waiting_tool', which
%% runs `fail_run/5' and emits the three events in that order. The test reads the
%% run-scoped trail with soma_event_store:by_run/2 and asserts the three event
%% indices ascend `tool.failed < step.failed < run.failed' -- same shape as
%% `test_error_trail_tool_step_run_failed_in_order' in soma_run_failure_SUITE.
test_missing_executable_reaches_run_failed_trail(_Config) ->
    StorePid = event_store_pid(),
    Missing = missing_executable_path(),
    false = filelib:is_file(Missing),
    Manifest = #{name => cli_missing_trail,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Missing,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cli_missing_trail,
               args => #{input => <<"hello">>}}],
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

%% Criterion 3: when the manifest's `executable' points at a file that exists but
%% is not executable, the cli adapter catches the permission raise from
%% `open_port' and the worker returns a named
%% `{error, {cli_executable_not_executable, _}}' instead of dying with a raw port
%% exception. Driven through the full session/run/tool-call stack via
%% soma_agent_session:start_run/2. The proof is that the run reaches `run.failed'
%% and the step's `tool.failed' event carries `payload.reason' matching
%% `{cli_executable_not_executable, _}' -- a named reason the worker can only have
%% produced by returning `{error, _}' rather than crashing on the raw raise.
test_non_executable_permission_error(_Config) ->
    StorePid = event_store_pid(),
    NonExec = non_executable_path(),
    Manifest = #{name => cli_non_exec,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => NonExec,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cli_non_exec,
               args => #{input => <<"hello">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.failed">>, Types),
    FailEvent = event_of_type(StorePid, RunId, <<"tool.failed">>),
    Payload = maps:get(payload, FailEvent),
    Reason = maps:get(reason, Payload),
    %% the worker returned a named not-executable error, not a raw port exception
    {cli_executable_not_executable, _} = Reason,
    ok.

%% Criterion 4: a run whose `cli' step's external program exits with a non-zero
%% status reaches `run.failed', and the failure payload carries that exit status.
%% Driven through the full session/run/tool-call stack via
%% soma_agent_session:start_run/2. The helper script does `exit 3'. With the old
%% code `collect_cli/2' only matched `{exit_status, 0}', so the worker blocked
%% forever and the per-step timer drove the run to `run.timeout' -- the wrong
%% terminal state, with the exit status lost. The proof is that the run reaches
%% `run.failed' (never `run.timeout'), and the `tool.failed' event's
%% `payload.reason' matches `{cli_exit_status, 3, _}' so the exit status 3 rides
%% in the payload.
test_non_zero_exit_carries_status(_Config) ->
    StorePid = event_store_pid(),
    Helper = write_exit_helper(3),
    Manifest = #{name => cli_exit_3,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% generous step budget so a wrong (timeout) outcome cannot be mistaken for a
    %% correct one -- if the worker blocked, the timer would fire and we would see
    %% run.timeout instead.
    Steps = [#{id => s1, tool => cli_exit_3,
               args => #{input => <<"ignored">>}, timeout_ms => 5000}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.failed">>, Types),
    %% never the wrong terminal state the old blocking code produced.
    false = lists:member(<<"run.timeout">>, Types),
    FailEvent = event_of_type(StorePid, RunId, <<"tool.failed">>),
    Payload = maps:get(payload, FailEvent),
    Reason = maps:get(reason, Payload),
    %% the exit status 3 rides in the failure payload.
    {cli_exit_status, 3, _} = Reason,
    ok.

%% Write a tiny cli helper that exits with the given status. It ignores argv and
%% never reads stdin, matching the cli adapter's argv input protocol. Returns the
%% absolute helper path.
write_exit_helper(Status) ->
    Base = filename:basedir(user_cache, "soma_cli_failure_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "exit.sh"),
    Script = iolist_to_binary(
               ["#!/bin/sh\n",
                "exit ", integer_to_list(Status), "\n"]),
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

%% Write a file that exists and is readable but has no execute bit (mode 8#644),
%% so opening a port on it fails with a permission error rather than a missing
%% path. Returns the absolute path to the freshly written file.
non_executable_path() ->
    Base = filename:basedir(user_cache, "soma_cli_failure_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "not_executable"),
    ok = file:write_file(Path, <<"#!/bin/sh\necho hi\n">>),
    ok = file:change_mode(Path, 8#644),
    Path.

%% 1-based index of the first occurrence of Elem in List.
index_of(Elem, List) ->
    index_of(Elem, List, 1).

index_of(Elem, [Elem | _], Idx) ->
    Idx;
index_of(Elem, [_ | Rest], Idx) ->
    index_of(Elem, Rest, Idx + 1).

%% An absolute path that does not exist, so the port open fails on a missing
%% executable.
missing_executable_path() ->
    Base = filename:basedir(user_cache, "soma_cli_failure_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    filename:join([Base, Unique, "no_such_executable"]).

%% Read the first event of Type for RunId.
event_of_type(StorePid, RunId, Type) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    [Event | _] = [E || E <- Events, maps:get(event_type, E) =:= Type],
    Event.

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

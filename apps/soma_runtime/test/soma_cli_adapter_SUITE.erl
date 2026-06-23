-module(soma_cli_adapter_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_cli_manifest_resolves_to_cli_descriptor/1]).
-export([test_cli_run_reaches_completed/1]).
-export([test_cli_tool_call_has_distinct_pid/1]).

all() ->
    [test_cli_manifest_resolves_to_cli_descriptor,
     test_cli_run_reaches_completed,
     test_cli_tool_call_has_distinct_pid].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    Helper = write_cli_helper(),
    [{started_apps, Started}, {cli_helper, Helper} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: a `cli' manifest (adapter cli, with an executable and an argv
%% list) registered in the running registry resolves through
%% soma_tool_registry:resolve_descriptor/1 to a `cli' descriptor.
test_cli_manifest_resolves_to_cli_descriptor(_Config) ->
    Manifest = #{name => cli_upper,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => "/bin/echo",
                 argv => ["hello"]},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, Descriptor} = soma_tool_registry:resolve_descriptor(cli_upper),
    #{adapter := cli,
      executable := "/bin/echo",
      argv := ["hello"]} = Descriptor,
    ok.

%% Criterion 2: a run whose step names a registered `cli' tool reaches the
%% `run.completed' state through the normal session/run/tool-call layers. The
%% test registers a real cli helper, starts a run that names it through the live
%% session entry point, and asserts the run's event trail ends at
%% `run.completed' -- proving the cli adapter branch launched the program and
%% the run drove it to a successful terminal state without bypassing any layer.
test_cli_run_reaches_completed(Config) ->
    Helper = ?config(cli_helper, Config),
    StorePid = event_store_pid(),
    Manifest = #{name => cli_upper,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cli_upper, args => #{input => <<"hello">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.completed">>, Types),
    ok.

%% Criterion 3: a `cli' tool invocation runs inside its own `soma_tool_call'
%% worker process. The worker pid appears on the step's `tool.started' and
%% `tool.succeeded' events, is the same pid on both, and differs from the
%% `soma_run' pid -- proving the cli adapter crosses a process boundary the same
%% way the erlang_module adapter does, rather than running inside the run.
test_cli_tool_call_has_distinct_pid(Config) ->
    Helper = ?config(cli_helper, Config),
    StorePid = event_store_pid(),
    Manifest = #{name => cli_upper,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cli_upper, args => #{input => <<"hello">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 100),
    RunPid = run_pid(),
    true = is_pid(RunPid),
    Events = soma_event_store:by_run(StorePid, RunId),
    StartedPid = event_tool_call_pid(Events, <<"tool.started">>),
    SucceededPid = event_tool_call_pid(Events, <<"tool.succeeded">>),
    %% the same worker pid travels on both events
    true = is_pid(StartedPid),
    StartedPid = SucceededPid,
    %% the cli call ran in its own worker, not inside the run
    true = (StartedPid =/= RunPid),
    ok.

%% Read the tool_call_pid off the single event of the given type for the cli
%% step.
event_tool_call_pid(Events, Type) ->
    [E] = [Ev || Ev <- Events, maps:get(event_type, Ev) =:= Type],
    maps:get(tool_call_pid, E).

%% The currently-live run process, read from soma_run_sup.
run_pid() ->
    Children = supervisor:which_children(soma_run_sup),
    case [Pid || {_Id, Pid, _Type, _Mods} <- Children, is_pid(Pid)] of
        [Pid | _] -> Pid;
        [] -> undefined
    end.

%% Write a tiny cli helper to a temp path. It reads its last argv argument,
%% uppercases it, and prints the result to stdout, then exits 0. It never reads
%% stdin, matching the argv input protocol the cli adapter uses.
write_cli_helper() ->
    Base = filename:basedir(user_cache, "soma_cli_adapter_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "cli_helper.sh"),
    Script = <<"#!/bin/sh\n"
               "for a in \"$@\"; do last=\"$a\"; done\n"
               "printf '%s' \"$last\" | tr '[:lower:]' '[:upper:]'\n">>,
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

wait_for_run_completed(_StorePid, _RunId, 0) ->
    {error, timeout};
wait_for_run_completed(StorePid, RunId, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(<<"run.completed">>, Types) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_run_completed(StorePid, RunId, N - 1)
    end.

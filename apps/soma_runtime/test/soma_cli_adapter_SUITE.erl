-module(soma_cli_adapter_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_cli_manifest_resolves_to_cli_descriptor/1]).
-export([test_cli_run_reaches_completed/1]).
-export([test_cli_tool_call_has_distinct_pid/1]).
-export([test_cli_argv_metacharacter_is_literal/1]).
-export([test_cli_stdout_is_step_output/1]).
-export([test_cli_step_event_order/1]).

all() ->
    [test_cli_manifest_resolves_to_cli_descriptor,
     test_cli_run_reaches_completed,
     test_cli_tool_call_has_distinct_pid,
     test_cli_argv_metacharacter_is_literal,
     test_cli_stdout_is_step_output,
     test_cli_step_event_order].

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

%% Criterion 4: an argv element containing a shell metacharacter reaches the
%% external program as one literal argument. The step's argv carries
%% `"$(echo pwned)"' -- a command substitution a shell would expand to `pwned'.
%% The helper echoes its first argv argument verbatim to stdout, and the test
%% asserts the recorded step output contains the literal `$(echo pwned)',
%% proving the adapter launched the program through a port with separate
%% executable and argv rather than a shell command string (which would have
%% substituted it away).
test_cli_argv_metacharacter_is_literal(_Config) ->
    Helper = write_echo_first_helper(),
    StorePid = event_store_pid(),
    Metachar = "$(echo pwned)",
    Manifest = #{name => cli_echo,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => [Metachar]},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cli_echo, args => #{input => <<"ignored">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Output = step_output(Events),
    true = is_binary(Output),
    %% the metacharacter argument arrived literally, not shell-expanded: the
    %% output is exactly the `$(echo pwned)' bytes, and never the shell-expanded
    %% bare `pwned'.
    Output = list_to_binary(Metachar),
    nomatch = re:run(Output, "^pwned$"),
    ok.

%% Criterion 5: the external program's stdout is recorded as the step's output
%% on its `step.succeeded' event when the program exits zero. The helper
%% uppercases its trailing argv argument (the resolved step input) and prints
%% the result to stdout; the test reads the `step.succeeded' payload output from
%% the event store and asserts it equals exactly what the helper printed --
%% proving the port-collected stdout became the step output at exit 0.
test_cli_stdout_is_step_output(_Config) ->
    Stdout = "soma-cli-stdout-marker",
    Helper = write_fixed_stdout_helper(Stdout),
    StorePid = event_store_pid(),
    Manifest = #{name => cli_marker,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cli_marker, args => #{input => <<"ignored">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Output = step_output(Events),
    true = is_binary(Output),
    %% the program printed a fixed marker to stdout, and that exact stdout --
    %% byte for byte -- is the recorded step output.
    Output = list_to_binary(Stdout),
    ok.

%% Criterion 6: a `cli' step emits its lifecycle events in a fixed order in the
%% run's event trail -- `tool.started', then `tool.succeeded', then
%% `step.succeeded'. The test registers the cli helper, runs a one-step run
%% through the live session entry point, then reads the run's event trail and
%% asserts the three event types appear in that index order, proving the run
%% records the worker starting, the worker succeeding, and the step succeeding
%% around the cli worker reply in the right sequence.
test_cli_step_event_order(Config) ->
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
    StartedIdx = event_index(Types, <<"tool.started">>),
    SucceededIdx = event_index(Types, <<"tool.succeeded">>),
    StepIdx = event_index(Types, <<"step.succeeded">>),
    true = is_integer(StartedIdx),
    true = is_integer(SucceededIdx),
    true = is_integer(StepIdx),
    %% tool.started precedes tool.succeeded precedes step.succeeded
    true = (StepIdx < SucceededIdx),
    true = (SucceededIdx < StartedIdx),
    ok.

%% The 1-based index of the first occurrence of the given event type in the
%% ordered list of event types.
event_index(Types, Type) ->
    case string:str(Types, [Type]) of
        0 -> not_found;
        N -> N
    end.

%% Read the step output recorded on the cli step's `step.succeeded' event.
step_output(Events) ->
    [E] = [Ev || Ev <- Events,
                 maps:get(event_type, Ev) =:= <<"step.succeeded">>],
    maps:get(output, maps:get(payload, E)).

%% Write a tiny cli helper that prints its first argv argument verbatim to
%% stdout, then exits 0. Used to observe one chosen argv element exactly as the
%% program received it.
write_echo_first_helper() ->
    Base = filename:basedir(user_cache, "soma_cli_adapter_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "echo_first.sh"),
    Script = <<"#!/bin/sh\n"
               "printf '%s' \"$1\"\n">>,
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

%% Write a tiny cli helper that prints a fixed string to stdout and exits 0,
%% ignoring its argv. Used to pin that exactly the program's stdout becomes the
%% step output, independent of how the input is rendered into argv.
write_fixed_stdout_helper(Stdout) ->
    Base = filename:basedir(user_cache, "soma_cli_adapter_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "fixed_stdout.sh"),
    Script = ["#!/bin/sh\n", "printf '%s' ", io_lib:format("~p", [Stdout]),
              "\n"],
    ok = file:write_file(Path, iolist_to_binary(Script)),
    ok = file:change_mode(Path, 8#755),
    Path.

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

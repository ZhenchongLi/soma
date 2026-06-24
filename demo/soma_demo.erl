%% Interactive demo for soma v0.2.
%%
%% Usage from `rebar3 shell':
%%
%%   c("demo/soma_demo").
%%   soma_demo:demo1().   % /bin/echo registered as a cli tool, show events
%%   soma_demo:demo2().   % three-step pipeline: fixed string -> upper -> echo
%%   soma_demo:demo3().   % cancel a live run mid-flight
%%
-module(soma_demo).
-export([demo1/0, demo2/0, demo3/0]).

%% -----------------------------------------------------------------------
%% Demo 1: /bin/echo as a cli tool
%%
%% Registers /bin/echo, runs one step, prints the event trail and output.
%%
%% Note on the output: the step's `args' map is the tool's input. For a
%% cli tool, that map is term-printed and appended as the last argv element,
%% so /bin/echo receives and prints the Erlang term repr of the args map.
%% -----------------------------------------------------------------------
demo1() ->
    application:ensure_all_started(soma_runtime),
    ok = soma_tool_registry:register_tool(#{
        name       => say,
        effect     => identity,
        idempotent => true,
        timeout_ms => 5000,
        adapter    => cli,
        executable => "/bin/echo",
        argv       => []
    }),
    {ok, S} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(S, [
        #{id => s1, tool => say, args => #{input => <<"hello soma">>}}
    ]),
    StorePid = store_pid(),
    ok = wait_for(StorePid, RunId, <<"run.completed">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    io:format("~n--- event trail ---~n"),
    [io:format("  ~s~n", [maps:get(event_type, E)]) || E <- Events],
    io:format("~nstep output: ~p~n", [step_output(Events, s1)]).

%% -----------------------------------------------------------------------
%% Demo 2: three-step pipeline
%%
%%   s1 (cli, fixed_greeting) -- prints "hello soma" to stdout, ignores argv
%%   s2 (cli, upper)          -- receives s1's binary output via from_step,
%%                               which is clean: binary -> "hello soma" as argv
%%   s3 (erlang, echo)        -- receives s2's binary output via from_step
%%
%% The key difference from demo1: `from_step' at the top level of a step's
%% args resolves to the prior step's raw output. When that output is a
%% binary (which cli tools always produce), it arrives at the next cli tool
%% as a clean string -- no term-repr wrapping.
%% -----------------------------------------------------------------------
demo2() ->
    application:ensure_all_started(soma_runtime),
    PrivDir = code:priv_dir(soma_tools),
    %% Write a one-shot helper that prints a fixed string to stdout.
    %% Its argv (including the adapter-appended input) is intentionally ignored.
    Greeting = write_fixed_helper("hello soma"),
    ok = soma_tool_registry:register_tool(#{
        name       => fixed_greeting,
        effect     => reader,
        idempotent => true,
        timeout_ms => 5000,
        adapter    => cli,
        executable => Greeting,
        argv       => []
    }),
    ok = soma_tool_registry:register_tool(#{
        name       => upper,
        effect     => reader,
        idempotent => true,
        timeout_ms => 5000,
        adapter    => cli,
        executable => filename:join([PrivDir, "cli", "soma_sample_upper"]),
        argv       => []
    }),
    {ok, S} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(S, [
        #{id => s1, tool => fixed_greeting, args => #{input => <<"ignored">>}},
        #{id => s2, tool => upper,          args => #{from_step => s1}},
        #{id => s3, tool => echo,           args => #{from_step => s2}}
    ]),
    StorePid = store_pid(),
    ok = wait_for(StorePid, RunId, <<"run.completed">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    io:format("~n--- pipeline outputs ---~n"),
    io:format("  s1 fixed_greeting : ~p~n", [step_output(Events, s1)]),
    io:format("  s2 upper          : ~p~n", [step_output(Events, s2)]),
    io:format("  s3 echo           : ~p~n", [step_output(Events, s3)]).

%% -----------------------------------------------------------------------
%% Demo 3: cancel a live run
%%
%% Starts a run whose step sleeps 30s, waits until tool.started is visible
%% in the event store, then sends cancel_run to the session. Shows that the
%% run reaches run.cancelled and the session stays alive.
%% -----------------------------------------------------------------------
demo3() ->
    application:ensure_all_started(soma_runtime),
    Slow = write_slow_helper(),
    ok = soma_tool_registry:register_tool(#{
        name       => slow,
        effect     => reader,
        idempotent => true,
        timeout_ms => 60000,
        adapter    => cli,
        executable => Slow,
        argv       => []
    }),
    {ok, S} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(S, [
        #{id => s1, tool => slow, args => #{input => <<"x">>}, timeout_ms => 60000}
    ]),
    StorePid = store_pid(),
    ok = wait_for(StorePid, RunId, <<"tool.started">>, 50),
    io:format("~nrun ~p is live (tool.started seen)~n", [RunId]),
    io:format("sending cancel...~n"),
    S ! {cancel_run, RunId},
    ok = wait_for(StorePid, RunId, <<"run.cancelled">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    io:format("~n--- event trail ---~n"),
    [io:format("  ~s~n", [maps:get(event_type, E)]) || E <- Events],
    io:format("~nsession still alive: ~p~n", [is_process_alive(S)]).

%%% Internal helpers

store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _, _} = lists:keyfind(soma_event_store, 1, Children),
    Pid.

wait_for(_, _, _, 0) -> {error, timeout};
wait_for(StorePid, RunId, Type, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(Type, Types) of
        true  -> ok;
        false ->
            timer:sleep(50),
            wait_for(StorePid, RunId, Type, N - 1)
    end.

step_output(Events, StepId) ->
    case [Ev || Ev <- Events,
                maps:get(event_type, Ev) =:= <<"step.succeeded">>,
                maps:get(step_id, Ev) =:= StepId] of
        [E | _] -> maps:get(output, maps:get(payload, E));
        []      -> not_found
    end.

%% A helper that ignores its argv and always prints a fixed string to stdout.
write_fixed_helper(Text) ->
    Path = "/tmp/soma_demo_fixed.sh",
    Script = iolist_to_binary(["#!/bin/sh\nprintf '%s' '", Text, "'\n"]),
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

%% A helper that sleeps forever (past any demo budget).
write_slow_helper() ->
    Path = "/tmp/soma_demo_slow.sh",
    ok = file:write_file(Path, <<"#!/bin/sh\nsleep 30\n">>),
    ok = file:change_mode(Path, 8#755),
    Path.

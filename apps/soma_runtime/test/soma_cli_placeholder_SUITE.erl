-module(soma_cli_placeholder_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_cli_argv_placeholder_from_step_replaces_doc/1]).

all() ->
    [test_cli_argv_placeholder_from_step_replaces_doc].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 5: a cli argv placeholder is rendered from resolved step args,
%% including a value supplied by `{doc => {from_step, s1}}'. Step one produces
%% document bytes through the real file_read tool. Step two names a cli manifest
%% whose argv contains the whole-argument placeholder `"{doc}"'. The helper
%% prints the argv slot where that placeholder lives. Driving this through
%% soma_agent_session:start_run/2 proves soma_run resolves the prior step output
%% and replaces the placeholder before soma_tool_call launches the port.
test_cli_argv_placeholder_from_step_replaces_doc(Config) ->
    StorePid = event_store_pid(),
    Root = ?config(priv_dir, Config),
    Doc = <<"placeholder-from-step-doc">>,
    Path = "doc.txt",
    ok = file:write_file(filename:join(Root, Path), Doc),
    Helper = write_print_second_arg_helper(),
    Manifest = #{name => cli_doc_placeholder,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => ["--doc", "{doc}"],
                 params => [#{name => <<"doc">>,
                              type => string,
                              required => true}]},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1,
               tool => file_read,
               args => #{path => Path, root => Root}},
             #{id => s2,
               tool => cli_doc_placeholder,
               args => #{doc => {from_step, s1}}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.completed">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Doc = step_output_for(Events, s1),
    Doc = step_output_for(Events, s2),
    ok.

write_print_second_arg_helper() ->
    Base = filename:basedir(user_cache, "soma_cli_placeholder_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "print_second_arg.sh"),
    Script = <<"#!/bin/sh\n"
               "printf '%s' \"$2\"\n">>,
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

step_output_for(Events, StepId) ->
    [E] = [Ev || Ev <- Events,
                 maps:get(event_type, Ev) =:= <<"step.succeeded">>,
                 maps:get(step_id, Ev) =:= StepId],
    maps:get(output, maps:get(payload, E)).

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

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

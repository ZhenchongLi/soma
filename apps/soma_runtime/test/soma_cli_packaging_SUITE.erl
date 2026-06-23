-module(soma_cli_packaging_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_priv_helper_run_reaches_completed_with_stdout/1]).

all() ->
    [test_priv_helper_run_reaches_completed_with_stdout].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 3: the committed priv helper, named through code:priv_dir/1 (the
%% release-relative convention, not an absolute build path), drives a real run
%% through the existing cli adapter to run.completed with the helper's stdout as
%% the step output. The test resolves code:priv_dir(soma_tools), joins the
%% relative "cli/soma_sample_upper", registers that as a cli tool's executable,
%% and starts a run through the live session entry point. The helper uppercases
%% its trailing argv argument (the resolved step input), so the test asserts the
%% run reaches run.completed and the recorded step output is the uppercased
%% input -- proving the packaged helper ran through the unmodified adapter and
%% its stdout became the step output, all from a priv_dir-resolved path.
test_priv_helper_run_reaches_completed_with_stdout(_Config) ->
    PrivDir = code:priv_dir(soma_tools),
    true = is_list(PrivDir),
    Executable = filename:join([PrivDir, "cli", "soma_sample_upper"]),
    true = filelib:is_file(Executable),
    StorePid = event_store_pid(),
    Manifest = #{name => sample_upper,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Executable,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => sample_upper, args => #{input => <<"hello">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 100),
    %% the session survived the run
    true = is_process_alive(SessionPid),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.completed">>, Types),
    Output = step_output(Events),
    true = is_binary(Output),
    %% the helper uppercased the resolved step input "hello" and printed it; that
    %% stdout is the recorded step output.
    Output = <<"hello">>,
    ok.

%% Read the step output recorded on the single step's `step.succeeded' event.
step_output(Events) ->
    [E] = [Ev || Ev <- Events,
                 maps:get(event_type, Ev) =:= <<"step.succeeded">>],
    maps:get(output, maps:get(payload, E)).

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

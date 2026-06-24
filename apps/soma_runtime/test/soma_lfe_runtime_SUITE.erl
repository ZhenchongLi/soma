-module(soma_lfe_runtime_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_dsl_demo_runs_to_completed/1]).
-export([test_dsl_demo_event_trail/1]).
-export([test_dsl_tool_calls_have_distinct_pids/1]).
-export([test_dsl_fail_step_fails_run_session_survives/1]).
-export([test_dsl_sleep_step_times_out/1]).
-export([test_dsl_sleep_step_cancels/1]).
-export([test_dsl_session_recovers_after_failed/1]).
-export([test_dsl_session_recovers_after_timeout/1]).
-export([test_dsl_session_recovers_after_cancelled/1]).

all() ->
    [test_dsl_demo_runs_to_completed,
     test_dsl_demo_event_trail,
     test_dsl_tool_calls_have_distinct_pids,
     test_dsl_fail_step_fails_run_session_survives,
     test_dsl_sleep_step_times_out,
     test_dsl_sleep_step_cancels,
     test_dsl_session_recovers_after_failed,
     test_dsl_session_recovers_after_timeout,
     test_dsl_session_recovers_after_cancelled].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% R1: DSL demo compiles and runs through start_run/2 to run.completed.
%% The three-step file_read -> echo -> file_write demo is compiled from LFE
%% source, passed to start_run/2, and the run must reach run.completed with
%% the output file holding the original input bytes.
test_dsl_demo_runs_to_completed(_Config) ->
    StorePid = event_store_pid(),
    Root = make_temp_root(),
    Bytes = <<"dsl demo bytes read -> echo -> write">>,
    ok = file:write_file(filename:join(Root, "in.txt"), Bytes),
    Source = iolist_to_binary([
        "(run\n",
        "  (step read file_read (args (path \"in.txt\") (root \"", Root, "\")))\n",
        "  (step echo echo (args (from_step read)))\n",
        "  (step write file_write (args (path \"out.txt\") (root \"", Root, "\") (bytes (from_step echo)))))\n"
    ]),
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.completed">>, 100),
    %% the output file holds the original input bytes
    {ok, Written} = file:read_file(filename:join(Root, "out.txt")),
    Bytes = Written,
    %% run.completed appears and run.failed does not
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.completed">>, Types),
    false = lists:member(<<"run.failed">>, Types),
    ok.

%% R2: Compiled demo produces the normal runtime event trail.
%% The run-scoped trail must be exactly:
%%   run.accepted -> run.started ->
%%   [step.started -> tool.started -> tool.succeeded -> step.succeeded] x 3 ->
%%   run.completed
%% in that order. This is a pin: any change to the event emission order breaks
%% this test intentionally.
%%
%% Staged-red: wrong expected value forces assertion failure before the
%% correct expectation is committed in the green phase.
test_dsl_demo_event_trail(_Config) ->
    StorePid = event_store_pid(),
    Root = make_temp_root(),
    Bytes = <<"trail bytes">>,
    ok = file:write_file(filename:join(Root, "in.txt"), Bytes),
    Source = iolist_to_binary([
        "(run\n",
        "  (step read file_read (args (path \"in.txt\") (root \"", Root, "\")))\n",
        "  (step echo echo (args (from_step read)))\n",
        "  (step write file_write (args (path \"out.txt\") (root \"", Root, "\") (bytes (from_step echo)))))\n"
    ]),
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.completed">>, 100),
    RunEvents = soma_event_store:by_run(StorePid, RunId),
    RunTrail = [maps:get(event_type, E) || E <- RunEvents],
    %% STAGED RED: wrong expected trail — extra phantom event forces failure.
    %% Green phase removes this phantom entry.
    ExpectedRunTrail =
        [<<"run.accepted">>,
         <<"run.started">>,
         <<"step.started">>, <<"tool.started">>,
         <<"tool.succeeded">>, <<"step.succeeded">>,
         <<"step.started">>, <<"tool.started">>,
         <<"tool.succeeded">>, <<"step.succeeded">>,
         <<"step.started">>, <<"tool.started">>,
         <<"tool.succeeded">>, <<"step.succeeded">>,
         <<"run.completed">>,
         <<"phantom.event.that.does.not.exist">>],
    ExpectedRunTrail = RunTrail,
    ok.

%% R3: Each tool call has its own worker pid; DSL does not bypass soma_tool_call.
%% Compile a two-step echo run; assert the tool_call_pid values on tool.started
%% events differ from each other and from the run pid.
test_dsl_tool_calls_have_distinct_pids(_Config) ->
    StorePid = event_store_pid(),
    Source = <<"(run\n"
               "  (step s1 echo (args (value \"a\")))\n"
               "  (step s2 echo (args (value \"b\"))))\n">>,
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.completed">>, 100),
    %% the run pid (if still alive; it exits after completing) is distinct from
    %% all tool-call worker pids
    Events = soma_event_store:by_run(StorePid, RunId),
    AllPids = [maps:get(tool_call_pid, E, undefined) || E <- Events],
    ToolPids = lists:usort([P || P <- AllPids, P =/= undefined]),
    %% one distinct pid per step
    2 = length(ToolPids),
    %% every worker pid is actually a pid
    true = lists:all(fun erlang:is_pid/1, ToolPids),
    ok.

%% R4: Compiled fail step fails the run without killing the session.
%% Compile a one-step run using fail (mode error), wait for run.failed, assert
%% the session pid is still alive.
test_dsl_fail_step_fails_run_session_survives(_Config) ->
    StorePid = event_store_pid(),
    Source = <<"(run (step s1 fail (args (mode error) (reason boom))))">>,
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% the run records run.failed and never run.completed
    true = lists:member(<<"run.failed">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    %% the session is still alive after the run failed
    true = is_process_alive(SessionPid),
    ok.

%% R5: Compiled sleep step can be timed out by the runtime.
%% Compile a step with sleep and a short timeout_ms; wait for run.timeout, assert
%% run.completed never appears.
test_dsl_sleep_step_times_out(_Config) ->
    StorePid = event_store_pid(),
    Source = <<"(run (step s1 sleep (args (ms 1000)) (timeout_ms 50)))">>,
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.timeout">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% the run records run.timeout and never run.completed
    true = lists:member(<<"run.timeout">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    ok.

%% R6: Compiled sleep step can be cancelled by the runtime.
%% Compile a slow sleep step; start the run, wait for tool.started, send
%% {cancel_run, RunId} to the session, wait for run.cancelled.
test_dsl_sleep_step_cancels(_Config) ->
    StorePid = event_store_pid(),
    Source = <<"(run (step s1 sleep (args (ms 5000))))">>,
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    %% wait until the run is actually waiting on the worker before cancelling
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 50),
    SessionPid ! {cancel_run, RunId},
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% the run records run.cancelled and never run.completed
    true = lists:member(<<"run.cancelled">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    ok.

%% R7 (failed half): session starts a fresh run after DSL-sourced failure.
%% After a DSL fail step drives the run to failed, the same session accepts a
%% fresh compiled echo run and reaches run.completed.
test_dsl_session_recovers_after_failed(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% first run: DSL fail step -> run.failed
    FailSource = <<"(run (step s1 fail (args (mode error) (reason boom))))">>,
    {ok, #{run := #{steps := FailSteps}}} = soma_lfe:compile(FailSource, #{}),
    {ok, FailRunId} = soma_agent_session:start_run(SessionPid, FailSteps),
    ok = wait_for_event(StorePid, FailRunId, <<"run.failed">>, 50),
    %% second run on the same session: plain compiled echo -> run.completed
    EchoSource = <<"(run (step s1 echo (args (value \"recover\"))))">>,
    {ok, #{run := #{steps := EchoSteps}}} = soma_lfe:compile(EchoSource, #{}),
    {ok, GoodRunId} = soma_agent_session:start_run(SessionPid, EchoSteps),
    ok = wait_for_event(StorePid, GoodRunId, <<"run.completed">>, 50),
    ok = wait_for_run_status(SessionPid, GoodRunId, completed, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    completed = maps:get(GoodRunId, Runs),
    ok.

%% R7 (timeout half): session starts a fresh run after DSL-sourced timeout.
%% After a DSL sleep step times out, the same session accepts a fresh compiled
%% echo run and reaches run.completed.
test_dsl_session_recovers_after_timeout(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% first run: DSL sleep step overruns its budget -> run.timeout
    TimeoutSource = <<"(run (step s1 sleep (args (ms 1000)) (timeout_ms 50)))">>,
    {ok, #{run := #{steps := TimeoutSteps}}} = soma_lfe:compile(TimeoutSource, #{}),
    {ok, TimeoutRunId} = soma_agent_session:start_run(SessionPid, TimeoutSteps),
    ok = wait_for_event(StorePid, TimeoutRunId, <<"run.timeout">>, 100),
    %% second run on the same session: plain compiled echo -> run.completed
    EchoSource = <<"(run (step s1 echo (args (value \"recover\"))))">>,
    {ok, #{run := #{steps := EchoSteps}}} = soma_lfe:compile(EchoSource, #{}),
    {ok, GoodRunId} = soma_agent_session:start_run(SessionPid, EchoSteps),
    ok = wait_for_event(StorePid, GoodRunId, <<"run.completed">>, 50),
    ok = wait_for_run_status(SessionPid, GoodRunId, completed, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    completed = maps:get(GoodRunId, Runs),
    ok.

%% R7 (cancelled half): session starts a fresh run after DSL-sourced cancellation.
%% After a DSL sleep step is cancelled, the same session accepts a fresh compiled
%% echo run and reaches run.completed.
test_dsl_session_recovers_after_cancelled(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% first run: DSL slow sleep step, cancelled mid-flight -> run.cancelled
    SlowSource = <<"(run (step s1 sleep (args (ms 5000))))">>,
    {ok, #{run := #{steps := SlowSteps}}} = soma_lfe:compile(SlowSource, #{}),
    {ok, CancelRunId} = soma_agent_session:start_run(SessionPid, SlowSteps),
    ok = wait_for_event(StorePid, CancelRunId, <<"tool.started">>, 50),
    SessionPid ! {cancel_run, CancelRunId},
    ok = wait_for_event(StorePid, CancelRunId, <<"run.cancelled">>, 50),
    %% second run on the same session: plain compiled echo -> run.completed
    EchoSource = <<"(run (step s1 echo (args (value \"recover\"))))">>,
    {ok, #{run := #{steps := EchoSteps}}} = soma_lfe:compile(EchoSource, #{}),
    {ok, GoodRunId} = soma_agent_session:start_run(SessionPid, EchoSteps),
    ok = wait_for_event(StorePid, GoodRunId, <<"run.completed">>, 50),
    ok = wait_for_run_status(SessionPid, GoodRunId, completed, 50),
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    completed = maps:get(GoodRunId, Runs),
    ok.

%% -- Helpers --

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

make_temp_root() ->
    Base = filename:basedir(user_cache, "soma_lfe_runtime_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Root = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Root, "x")),
    Root.

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

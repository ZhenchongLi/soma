-module(soma_cli_lifecycle_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_cli_overrun_reaches_timeout/1,
         test_cli_external_process_dead_after_timeout/1,
         test_cli_cancel_reaches_cancelled/1,
         test_cli_external_process_dead_after_cancel/1]).

all() ->
    [test_cli_overrun_reaches_timeout,
     test_cli_external_process_dead_after_timeout,
     test_cli_cancel_reaches_cancelled,
     test_cli_external_process_dead_after_cancel].

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

%% Criterion 2: the external OS process a timed-out `cli' step launched is no
%% longer alive once the run has reached `timeout'. The proof is a side effect
%% the helper produces only if it runs to completion: it sleeps past the step's
%% `timeout_ms', then `touch'es a marker file. The run is driven to `timeout'
%% through the real session/run/tool-call layers; we then wait past the helper's
%% sleep window and assert the marker file does NOT exist. A killed process never
%% writes the marker; a leaked orphan writes it once its sleep elapses, so the
%% marker's absence is the liveness check.
test_cli_external_process_dead_after_timeout(_Config) ->
    {Helper, Marker} = write_marker_helper(),
    StorePid = event_store_pid(),
    %% the marker path travels as a literal argv element, so the helper reads it
    %% verbatim as `$1' -- no shell interpolation, matching the cli adapter's
    %% executable+argv contract.
    Manifest = #{name => cli_marker,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => [Marker]},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% the helper sleeps 2s then writes the marker; the step budget is 100ms, so
    %% the per-step timer drives the run to `timeout' long before the sleep ends.
    Steps = [#{id => s1, tool => cli_marker,
               args => #{input => <<"ignored">>}, timeout_ms => 100}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.timeout">>, 100),
    %% wait past the helper's 2s sleep window: a leaked orphan would write the
    %% marker after its sleep elapses, so by now an orphan's side effect is visible.
    timer:sleep(3000),
    %% a killed external process never reached its `touch', so the marker is absent.
    false = filelib:is_file(Marker),
    ok.

%% Criterion 3: cancelling a run while its `cli' step is active drives the run to
%% the terminal `cancelled' state. Driven through the real session/run layers: the
%% session starts a run of one `cli' step whose external helper sleeps far longer
%% than the test takes, with a generous step budget so the per-step timer does not
%% fire. The run reaches `waiting_tool' reading the port; once the worker has
%% emitted `tool.started' the step is in flight, so the test sends the session's
%% own cancel interface `{cancel_run, RunId}', which the session forwards as
%% `cancel' to the run. The run kills the worker, records `run.cancelled', and
%% moves to the `cancelled' terminal state. The run records `run.cancelled' and
%% never `run.completed', proving the cancel path drives a `cli' step to the
%% `cancelled' terminal state the same way it drives an in-BEAM step.
test_cli_cancel_reaches_cancelled(_Config) ->
    Helper = write_sleep_helper(),
    StorePid = event_store_pid(),
    Manifest = #{name => cli_cancel_sleep,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% the helper sleeps 5s; the step budget is 60s so the per-step timer never
    %% fires -- the only thing that ends the step is the cancel.
    Steps = [#{id => s1, tool => cli_cancel_sleep,
               args => #{input => <<"ignored">>}, timeout_ms => 60000}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    %% wait until the step is actually in flight before cancelling.
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),
    %% cancel through the session's own interface, the README-named cancel path.
    SessionPid ! {cancel_run, RunId},
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% the run records run.cancelled and never run.completed
    true = lists:member(<<"run.cancelled">>, Types),
    false = lists:member(<<"run.completed">>, Types),
    ok.

%% Criterion 4: the external OS process a cancelled `cli' step launched is no
%% longer alive once the run has reached `cancelled'. The proof mirrors the
%% timeout case: the helper sleeps, then `touch'es a marker file only if it runs
%% to completion. The run is driven through the real session/run layers with a
%% generous step budget so the per-step timer never fires; once the step is in
%% flight (the worker has emitted `tool.started') the test cancels through the
%% session's own `{cancel_run, RunId}' interface, driving the run to `cancelled'.
%% We then wait past the helper's sleep window and assert the marker does NOT
%% exist: a killed external process never reaches its `touch', while a leaked
%% orphan writes the marker once its sleep elapses, so the marker's absence is
%% the liveness check that the cancel path killed the external process too.
test_cli_external_process_dead_after_cancel(_Config) ->
    {Helper, Marker} = write_marker_helper(),
    StorePid = event_store_pid(),
    Manifest = #{name => cli_cancel_marker,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 60000,
                 adapter => cli,
                 executable => Helper,
                 argv => [Marker]},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% the helper sleeps 2s then writes the marker; the step budget is 60s so the
    %% per-step timer never fires -- only the cancel ends the step.
    Steps = [#{id => s1, tool => cli_cancel_marker,
               args => #{input => <<"ignored">>}, timeout_ms => 60000}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    %% wait until the step is actually in flight before cancelling.
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),
    %% cancel through the session's own interface, the README-named cancel path.
    SessionPid ! {cancel_run, RunId},
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    %% wait past the helper's 2s sleep window: a leaked orphan would write the
    %% marker after its sleep elapses, so by now an orphan's side effect is visible.
    timer:sleep(3000),
    %% a killed external process never reached its `touch', so the marker is absent.
    false = filelib:is_file(Marker),
    ok.

%% Write a cli helper that sleeps past any step budget, then `touch'es the marker
%% file whose path arrives as its first argv argument. Reaching the touch is the
%% only way the marker appears, so the marker proves the helper ran to completion
%% -- i.e. was never killed mid-sleep. Returns `{HelperPath, MarkerPath}'.
write_marker_helper() ->
    Base = filename:basedir(user_cache, "soma_cli_lifecycle_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "marker.sh"),
    Marker = filename:join(Dir, "marker.out"),
    Script = <<"#!/bin/sh\n"
               "sleep 2\n"
               "touch \"$1\"\n">>,
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    {Path, Marker}.

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

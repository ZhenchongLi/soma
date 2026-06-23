-module(soma_cli_failure_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_missing_executable_named_error/1]).
-export([test_missing_executable_reaches_run_failed_trail/1]).
-export([test_non_executable_permission_error/1]).
-export([test_non_zero_exit_carries_status/1]).
-export([test_failure_payload_carries_output_excerpt/1]).
-export([test_output_over_limit_fails_with_limit_reason/1]).

%% The cli adapter's configured output byte limit. Pinned here to the module-level
%% constant in soma_tool_call so the limit-exceeded reason can be asserted exactly.
-define(CLI_OUTPUT_LIMIT, 65536).

all() ->
    [test_missing_executable_named_error,
     test_missing_executable_reaches_run_failed_trail,
     test_non_executable_permission_error,
     test_non_zero_exit_carries_status,
     test_failure_payload_carries_output_excerpt,
     test_output_over_limit_fails_with_limit_reason].

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

%% Criterion 5: when the external program emits diagnostic output before failing,
%% the failure payload's excerpt carries that captured output. Driven through the
%% full session/run/tool-call stack via soma_agent_session:start_run/2. The helper
%% prints a known short marker (well under the byte limit) to stdout, then
%% `exit 1'. Because a spawn_executable port merges stdout and stderr, the marker
%% lands in the merged stream `collect_cli/2' captures, and the non-zero exit
%% builds `{cli_exit_status, 1, Excerpt}' from it. The proof is that the
%% `tool.failed' event's `payload.reason' is `{cli_exit_status, 1, Excerpt}' and
%% `Excerpt' contains the marker bytes -- the merged captured output rode into the
%% failure payload.
test_failure_payload_carries_output_excerpt(_Config) ->
    StorePid = event_store_pid(),
    Marker = <<"DIAGNOSTIC-MARKER-9f3a">>,
    Helper = write_diagnostic_helper(Marker, 1),
    Manifest = #{name => cli_diag_excerpt,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => cli_diag_excerpt,
               args => #{input => <<"ignored">>}, timeout_ms => 5000}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 100),
    FailEvent = event_of_type(StorePid, RunId, <<"tool.failed">>),
    Payload = maps:get(payload, FailEvent),
    Reason = maps:get(reason, Payload),
    {cli_exit_status, 1, Excerpt} = Reason,
    %% the merged captured output rode into the failure payload.
    true = is_binary(Excerpt),
    true = contains(Excerpt, Marker),
    ok.

%% Criterion 6: when the external program's merged output exceeds the adapter's
%% configured byte limit, the worker stops collecting rather than buffering the
%% whole stream, kills the port, and fails the run with a reason that names the
%% limit. Driven through the full session/run/tool-call stack via
%% soma_agent_session:start_run/2. The helper emits far more than the limit's worth
%% of bytes and then sleeps far past any step budget: a worker that kept buffering
%% would never finish, so the only way the run reaches `run.failed' (and not
%% `run.timeout') is the bounded collect loop tripping the limit. The proof is that
%% the `tool.failed' event's `payload.reason' matches
%% `{cli_output_limit_exceeded, Limit}', with `Limit' equal to the configured byte
%% limit.
test_output_over_limit_fails_with_limit_reason(_Config) ->
    StorePid = event_store_pid(),
    Helper = write_flood_helper(?CLI_OUTPUT_LIMIT),
    Manifest = #{name => cli_flood,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => Helper,
                 argv => []},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    %% generous step budget: a worker that kept buffering would hit the timeout and
    %% the run would land on run.timeout. The bounded loop must trip the limit and
    %% fail the run well before this budget elapses.
    Steps = [#{id => s1, tool => cli_flood,
               args => #{input => <<"ignored">>}, timeout_ms => 5000}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.failed">>, Types),
    %% never the wrong terminal state a buffering worker would produce.
    false = lists:member(<<"run.timeout">>, Types),
    FailEvent = event_of_type(StorePid, RunId, <<"tool.failed">>),
    Payload = maps:get(payload, FailEvent),
    Reason = maps:get(reason, Payload),
    %% the reason names the configured byte limit.
    {cli_output_limit_exceeded, ?CLI_OUTPUT_LIMIT} = Reason,
    ok.

%% Write a cli helper that floods stdout with far more than Limit bytes, then
%% sleeps far past any step budget. The flood is emitted in chunks so the running
%% byte count crosses the limit before the program would ever exit; the trailing
%% sleep means a worker that kept buffering would block here rather than finish, so
%% only a bounded collect loop can drive the run to a clean limit failure. Returns
%% the absolute helper path.
write_flood_helper(Limit) ->
    Base = filename:basedir(user_cache, "soma_cli_failure_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "flood.sh"),
    %% emit ~4x the limit in 1 KiB lines via `yes', then sleep so a buffering
    %% worker never reaches an exit.
    Lines = (Limit * 4) div 1024 + 1,
    Script = iolist_to_binary(
               ["#!/bin/sh\n",
                "yes \"", lists:duplicate(1023, $A), "\" | head -n ",
                integer_to_list(Lines), "\n",
                "sleep 30\n"]),
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

%% Write a cli helper that prints the given marker to stdout, then exits with the
%% given status. The marker is short (well under the adapter's byte limit), so the
%% excerpt carries it whole. Returns the absolute helper path.
write_diagnostic_helper(Marker, Status) ->
    Base = filename:basedir(user_cache, "soma_cli_failure_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, "diag.sh"),
    Script = iolist_to_binary(
               ["#!/bin/sh\n",
                "printf '%s' '", Marker, "'\n",
                "exit ", integer_to_list(Status), "\n"]),
    ok = file:write_file(Path, Script),
    ok = file:change_mode(Path, 8#755),
    Path.

%% True if Haystack contains Needle as a substring of bytes.
contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

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

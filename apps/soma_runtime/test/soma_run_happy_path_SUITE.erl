-module(soma_run_happy_path_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_sup_has_four_live_children/1]).
-export([test_registry_seeded_with_v01_tools/1]).
-export([test_session_starts_and_holds_id/1]).
-export([test_session_started_event_recorded/1]).
-export([test_start_run_returns_id_and_spawns_run/1]).
-export([test_run_accepted_event_recorded/1]).
-export([test_multi_step_runs_sequentially_to_completed/1]).
-export([test_each_tool_call_has_distinct_pid/1]).
-export([test_event_trail_in_order/1]).
-export([test_per_step_events_carry_real_ids/1]).

all() ->
    [test_sup_has_four_live_children,
     test_registry_seeded_with_v01_tools,
     test_session_starts_and_holds_id,
     test_session_started_event_recorded,
     test_start_run_returns_id_and_spawns_run,
     test_run_accepted_event_recorded,
     test_multi_step_runs_sequentially_to_completed,
     test_each_tool_call_has_distinct_pid,
     test_event_trail_in_order,
     test_per_step_events_carry_real_ids].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: booting the soma_runtime application brings up soma_sup with
%% four live children, in order: soma_event_store, soma_tool_registry,
%% soma_session_sup, soma_run_sup.
test_sup_has_four_live_children(_Config) ->
    SupPid = whereis(soma_sup),
    true = is_pid(SupPid),
    true = is_process_alive(SupPid),
    Children = supervisor:which_children(soma_sup),
    Ids = [Id || {Id, _Child, _Type, _Mods} <- Children],
    Expected = [soma_event_store, soma_tool_registry, soma_session_sup,
                soma_run_sup],
    true = lists:all(fun(Id) -> lists:member(Id, Ids) end, Expected),
    4 = length(Children),
    Pids = [Pid || {_Id, Pid, _Type, _Mods} <- Children],
    true = lists:all(fun(Pid) -> is_pid(Pid) andalso is_process_alive(Pid) end,
                     Pids),
    ok.

%% Criterion 2: the registry the booted runtime owns is seeded with the five
%% v0.1 tools, and each tool name resolves through soma_tool_registry:resolve/1
%% to its behaviour module.
test_registry_seeded_with_v01_tools(_Config) ->
    {ok, soma_tool_echo} = soma_tool_registry:resolve(echo),
    {ok, soma_tool_sleep} = soma_tool_registry:resolve(sleep),
    {ok, soma_tool_fail} = soma_tool_registry:resolve(fail),
    {ok, soma_tool_file_read} = soma_tool_registry:resolve(file_read),
    {ok, soma_tool_file_write} = soma_tool_registry:resolve(file_write),
    ok.

%% Criterion 3: starting a session returns a live soma_agent_session process
%% that holds a session_id, reported back through get_status/1.
test_session_starts_and_holds_id(_Config) ->
    {ok, Pid} = soma_agent_session:start_link(#{}),
    true = is_pid(Pid),
    true = is_process_alive(Pid),
    Status = soma_agent_session:get_status(Pid),
    SessionId = maps:get(session_id, Status),
    true = SessionId =/= undefined,
    ok.

%% Criterion 4: when a session starts, a `session.started' event is recorded in
%% the event store for that session, readable back via by_session/2.
test_session_started_event_recorded(_Config) ->
    StorePid = event_store_pid(),
    {ok, Pid} = soma_agent_session:start_link(#{}),
    SessionId = maps:get(session_id, soma_agent_session:get_status(Pid)),
    Events = soma_event_store:by_session(StorePid, SessionId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"session.started">>, Types),
    ok.

%% Criterion 5: submitting a run request returns a run_id and starts a soma_run
%% process under soma_run_sup, without bypassing the session layer.
test_start_run_returns_id_and_spawns_run(_Config) ->
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(SessionPid, []),
    true = RunId =/= undefined,
    Children = supervisor:which_children(soma_run_sup),
    RunPids = [Pid || {_Id, Pid, _Type, _Mods} <- Children, is_pid(Pid)],
    1 = length(RunPids),
    true = lists:all(fun(Pid) -> is_process_alive(Pid) end, RunPids),
    ok.

%% Criterion 6: when a run request is accepted, a `run.accepted' event is
%% recorded in the event store for that run, readable back via by_run/2.
test_run_accepted_event_recorded(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    {ok, RunId} = soma_agent_session:start_run(SessionPid, []),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.accepted">>, Types),
    ok.

%% Criterion 7: a multi-step run executes strictly sequentially -- step N+1's
%% tool call starts only after step N has succeeded -- and the run reaches the
%% `completed' state. Proven from the recorded event trail: for two steps the
%% trail must show step one fully done (step.succeeded) before step two starts
%% (step.started), and end with `run.completed'.
test_multi_step_runs_sequentially_to_completed(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
             #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Trail = [{maps:get(event_type, E), maps:get(step_id, E)} || E <- Events],
    %% step one must succeed before step two even starts
    S1Done = index_of({<<"step.succeeded">>, s1}, Trail),
    S2Start = index_of({<<"step.started">>, s2}, Trail),
    true = is_integer(S1Done),
    true = is_integer(S2Start),
    true = S1Done < S2Start,
    %% and the run reaches completed
    Types = [T || {T, _} <- Trail],
    true = lists:member(<<"run.completed">>, Types),
    ok.

%% Criterion 8: each step's tool invocation runs in its own soma_tool_call
%% process whose pid differs from the soma_run pid and from every other step's
%% tool-call pid. Proven by reading each tool call's worker pid from the event
%% trail and asserting they are all distinct from one another and from the run.
test_each_tool_call_has_distinct_pid(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
             #{id => s2, tool => echo, args => #{value => <<"b">>}},
             #{id => s3, tool => echo, args => #{value => <<"c">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    RunPid = run_pid(RunId),
    true = is_pid(RunPid),
    Events = soma_event_store:by_run(StorePid, RunId),
    AllPids = [maps:get(tool_call_pid, E, undefined) || E <- Events],
    ToolPids = [P || P <- AllPids, P =/= undefined],
    %% one tool-call worker pid per step
    3 = length(ToolPids),
    %% every worker pid is actually a pid
    true = lists:all(fun erlang:is_pid/1, ToolPids),
    %% all worker pids are distinct from each other
    3 = length(lists:usort(ToolPids)),
    %% no worker pid is the run pid
    false = lists:member(RunPid, ToolPids),
    ok.

%% Criterion 9: after a successful run the event store holds the full ordered
%% trail. `session.started' (readable via by_session/2) precedes the run trail;
%% the run trail (readable via by_run/2) is `run.accepted -> run.started', then
%% per step `step.started -> tool.started -> tool.succeeded -> step.succeeded',
%% then `run.completed', in that exact order.
test_event_trail_in_order(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    SessionId = maps:get(session_id, soma_agent_session:get_status(SessionPid)),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
             #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    %% the run-scoped trail, in append order
    RunEvents = soma_event_store:by_run(StorePid, RunId),
    RunTrail = [maps:get(event_type, E) || E <- RunEvents],
    ExpectedRunTrail =
        [<<"run.accepted">>,
         <<"run.started">>,
         <<"step.started">>, <<"tool.started">>,
         <<"tool.succeeded">>, <<"step.succeeded">>,
         <<"step.started">>, <<"tool.started">>,
         <<"tool.succeeded">>, <<"step.succeeded">>,
         <<"run.completed">>],
    ExpectedRunTrail = RunTrail,
    %% session.started is recorded against the session and precedes the run
    SessionEvents = soma_event_store:by_session(StorePid, SessionId),
    SessionTrail = [maps:get(event_type, E) || E <- SessionEvents],
    SStarted = index_of(<<"session.started">>, SessionTrail),
    RAccepted = index_of(<<"run.accepted">>, SessionTrail),
    true = is_integer(SStarted),
    true = is_integer(RAccepted),
    true = SStarted < RAccepted,
    ok.

%% Criterion 10: every per-step event a run emits (step.started, tool.started,
%% tool.succeeded, step.succeeded) carries the real step_id and tool_call_id for
%% that step -- never `undefined'. Proven by reading the per-step events back
%% from the store and asserting both ids are present on each.
test_per_step_events_carry_real_ids(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
             #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    PerStepTypes = [<<"step.started">>, <<"tool.started">>,
                    <<"tool.succeeded">>, <<"step.succeeded">>],
    PerStepEvents = [E || E <- Events,
                          lists:member(maps:get(event_type, E), PerStepTypes)],
    %% two steps, four per-step events each
    8 = length(PerStepEvents),
    %% none of them carries an undefined step_id or tool_call_id
    true = lists:all(
             fun(E) ->
                 maps:get(step_id, E) =/= undefined andalso
                 maps:get(tool_call_id, E) =/= undefined
             end,
             PerStepEvents),
    ok.

run_pid(_RunId) ->
    Children = supervisor:which_children(soma_run_sup),
    case [Pid || {_Id, Pid, _Type, _Mods} <- Children, is_pid(Pid)] of
        [Pid | _] -> Pid;
        [] -> undefined
    end.

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

index_of(Elem, List) ->
    index_of(Elem, List, 1).

index_of(_Elem, [], _N) ->
    undefined;
index_of(Elem, [Elem | _], N) ->
    N;
index_of(Elem, [_ | Rest], N) ->
    index_of(Elem, Rest, N + 1).

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

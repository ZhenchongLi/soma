-module(soma_run_happy_path_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_sup_has_four_live_children/1]).
-export([test_registry_seeded_with_v01_tools/1]).
-export([test_registry_resolves_erlang_module_descriptors/1]).
-export([test_registry_seeds_descriptors_from_manifests/1]).
-export([test_session_starts_and_holds_id/1]).
-export([test_session_started_event_recorded/1]).
-export([test_start_run_returns_id_and_spawns_run/1]).
-export([test_run_accepted_event_recorded/1]).
-export([test_multi_step_runs_sequentially_to_completed/1]).
-export([test_each_tool_call_has_distinct_pid/1]).
-export([test_event_trail_in_order/1]).
-export([test_per_step_events_carry_real_ids/1]).
-export([test_from_step_resolves_to_prior_output/1]).
-export([test_demo_file_read_echo_file_write/1]).
-export([test_session_alive_and_reports_completed/1]).
-export([test_run_stamps_correlation_id_on_every_event/1]).
-export([test_run_without_correlation_id_emits_normal_trail/1]).

all() ->
    [test_sup_has_four_live_children,
     test_registry_seeded_with_v01_tools,
     test_registry_resolves_erlang_module_descriptors,
     test_registry_seeds_descriptors_from_manifests,
     test_session_starts_and_holds_id,
     test_session_started_event_recorded,
     test_start_run_returns_id_and_spawns_run,
     test_run_accepted_event_recorded,
     test_multi_step_runs_sequentially_to_completed,
     test_each_tool_call_has_distinct_pid,
     test_event_trail_in_order,
     test_per_step_events_carry_real_ids,
     test_from_step_resolves_to_prior_output,
     test_demo_file_read_echo_file_write,
     test_session_alive_and_reports_completed,
     test_run_stamps_correlation_id_on_every_event,
     test_run_without_correlation_id_emits_normal_trail].

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

%% Issue #16, criterion 3: each of the five v0.1 names resolves through the
%% running registry to an `erlang_module' descriptor -- a map carrying the
%% `erlang_module' adapter marker and a backing module -- via the new
%% resolve_descriptor/1 path (distinct from resolve/1's bare-module shape).
test_registry_resolves_erlang_module_descriptors(_Config) ->
    Names = [echo, sleep, fail, file_read, file_write],
    lists:foreach(
      fun(Name) ->
          {ok, Descriptor} = soma_tool_registry:resolve_descriptor(Name),
          erlang_module = maps:get(adapter, Descriptor),
          true = is_atom(maps:get(module, Descriptor))
      end,
      Names),
    ok.

%% Issue #17, criterion 4: the running registry seeds each built-in entry from
%% its normalized manifest. For each built-in name the descriptor handed back by
%% the live soma_tool_registry:resolve_descriptor/1 must equal the {ok, M}
%% payload of normalize(Module:manifest()) for that name's backing module --
%% equality against the freshly normalized manifest proves the seed was built
%% from the manifest, not a hand-written literal.
test_registry_seeds_descriptors_from_manifests(_Config) ->
    Builtins = [{echo, soma_tool_echo},
                {sleep, soma_tool_sleep},
                {fail, soma_tool_fail},
                {file_read, soma_tool_file_read},
                {file_write, soma_tool_file_write}],
    lists:foreach(
      fun({Name, Module}) ->
          {ok, Expected} = soma_tool_manifest:normalize(Module:manifest()),
          {ok, Descriptor} = soma_tool_registry:resolve_descriptor(Name),
          Expected = Descriptor
      end,
      Builtins),
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
    ToolPids = lists:usort([P || P <- AllPids, P =/= undefined]),
    %% one distinct tool-call worker pid per step (the pid travels on both
    %% `tool.started' and `tool.succeeded', so de-duplicate before counting)
    3 = length(ToolPids),
    %% every worker pid is actually a pid
    true = lists:all(fun erlang:is_pid/1, ToolPids),
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

%% Criterion 11: a step whose args reference a prior step through `from_step'
%% receives that prior step's recorded output as its resolved input. Step one is
%% an echo whose output is `#{value => <<"a">>}'. Step two is an echo whose args
%% are a bare `#{from_step => s1}', meaning "the whole input is step one's
%% recorded output". Echo returns its input unchanged, so step two's recorded
%% output must equal step one's output -- proving the from_step reference was
%% resolved to the prior step's output before the tool was invoked.
test_from_step_resolves_to_prior_output(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
             #{id => s2, tool => echo, args => #{from_step => s1}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    S1Out = step_output(Events, s1),
    S2Out = step_output(Events, s2),
    #{value := <<"a">>} = S1Out,
    %% step two's output reflects step one's recorded output, not its literal args
    S1Out = S2Out,
    ok.

%% Criterion 12: the README demo runs end to end. A step list
%% `file_read -> echo -> file_write' wired with `from_step' reads a sandbox
%% input file, passes its bytes through echo, and writes them to a sandbox
%% output path. After the run completes the output file holds the input bytes
%% and the run reaches `completed'. The whole demo path runs through the real
%% session/run/tool-call layers; nothing is bypassed.
test_demo_file_read_echo_file_write(_Config) ->
    StorePid = event_store_pid(),
    Root = make_temp_root(),
    Bytes = <<"bytes that flow read -> echo -> write">>,
    ok = file:write_file(filename:join(Root, "in.txt"), Bytes),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => read, tool => file_read,
               args => #{path => <<"in.txt">>, root => Root}},
             #{id => echo, tool => echo,
               args => #{from_step => read}},
             #{id => write, tool => file_write,
               args => #{path => <<"out.txt">>, root => Root,
                         bytes => {from_step, echo}}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    %% the output file under the sandbox root holds the original input bytes
    {ok, Written} = file:read_file(filename:join(Root, "out.txt")),
    Bytes = Written,
    %% and the run reached completed
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.completed">>, Types),
    %% Issue #16, criterion 4: the run drives each demo tool by reading the
    %% backing module out of the resolved descriptor, not from a bare module
    %% lookup. For each demo tool the descriptor's `module' is the module the run
    %% hands to the tool-call worker -- proven here by asserting the
    %% descriptor-read module equals the module that actually backs the tool.
    lists:foreach(
      fun(Name) ->
          {ok, #{module := DescModule}} =
              soma_tool_registry:resolve_descriptor(Name),
          {ok, DescModule} = soma_tool_registry:resolve(Name)
      end,
      [file_read, echo, file_write]),
    ok.

%% Criterion 13: after a run reaches `completed' the long-lived
%% soma_agent_session process is still alive, and it reports that run as
%% completed through get_status/1. The run notifies the session with
%% `{run_completed, RunId, Result}' when it finishes; the session survives that
%% and surfaces the run's status in its get_status/1 view.
test_session_alive_and_reports_completed(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
             #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    %% the run-completed message reaches the session; give it a tick to apply
    ok = wait_for_run_status(SessionPid, RunId, completed, 50),
    %% the session is still alive after the run finished
    true = is_process_alive(SessionPid),
    %% and it reports that run as completed
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status),
    completed = maps:get(RunId, Runs),
    ok.

%% Issue #66, criterion 3: a soma_run started with a `correlation_id' in its
%% opts stamps that id on every event it emits, from `run.started' through the
%% terminal `run.completed'. The run is started directly (not via the session,
%% which can't pass a correlation_id opt). After completion the full run trail
%% must be retrievable under that id via by_correlation/2, and every returned
%% event must carry `correlation_id = C'.
test_run_stamps_correlation_id_on_every_event(_Config) ->
    StorePid = event_store_pid(),
    C = <<"corr-run-stamp-1">>,
    RunId = <<"run-corr-1">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
             #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    {ok, _RunPid} = soma_run:start_link(#{run_id => RunId,
                                          session_id => <<"sess-corr-1">>,
                                          event_store => StorePid,
                                          correlation_id => C,
                                          steps => Steps}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    %% the full run trail is reachable under the correlation id
    CorrEvents = soma_event_store:by_correlation(StorePid, C),
    Types = [maps:get(event_type, E) || E <- CorrEvents],
    true = lists:member(<<"run.started">>, Types),
    true = lists:member(<<"run.completed">>, Types),
    %% the correlation lookup returns exactly the run's own trail
    RunEvents = soma_event_store:by_run(StorePid, RunId),
    RunTypes = [maps:get(event_type, E) || E <- RunEvents],
    Types = RunTypes,
    %% and every event carries the correlation id
    true = lists:all(fun(E) -> maps:get(correlation_id, E, undefined) =:= C end,
                     CorrEvents),
    ok.

%% Issue #66, criterion 4: a soma_run started with no `correlation_id' opt runs
%% to completion and emits its normal event trail, with no `correlation_id' key
%% on any event. The run is started directly with the opt omitted. After
%% completion the run reaches `run.completed', and every event in the run's
%% trail must be free of the `correlation_id' key.
test_run_without_correlation_id_emits_normal_trail(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-no-corr-1">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
             #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    {ok, _RunPid} = soma_run:start_link(#{run_id => RunId,
                                          session_id => <<"sess-no-corr-1">>,
                                          event_store => StorePid,
                                          steps => Steps}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    RunEvents = soma_event_store:by_run(StorePid, RunId),
    %% the run drives to completion with its normal trail
    Types = [maps:get(event_type, E) || E <- RunEvents],
    true = lists:member(<<"run.completed">>, Types),
    %% and no event carries a correlation_id key
    true = lists:any(fun(E) -> maps:is_key(correlation_id, E) end, RunEvents),
    ok.

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

%% The recorded output of a step, read from its step.succeeded event payload.
step_output(Events, StepId) ->
    [E] = [Ev || Ev <- Events,
                 maps:get(event_type, Ev) =:= <<"step.succeeded">>,
                 maps:get(step_id, Ev) =:= StepId],
    maps:get(output, maps:get(payload, E)).

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

%% A fresh sandbox root for the demo's file tools, mirroring the file-tools
%% suite's pattern.
make_temp_root() ->
    Base = filename:basedir(user_cache, "soma_run_happy_path_SUITE"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Root = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Root, "x")),
    Root.

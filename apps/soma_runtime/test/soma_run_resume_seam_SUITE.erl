-module(soma_run_resume_seam_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_resume_emits_no_start_events_for_committed_steps/1]).

all() ->
    [test_resume_emits_no_start_events_for_committed_steps].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: a soma_run started with a full `steps' list, a `pending' suffix
%% that omits the first N steps, and an `outputs' map seeding those N steps emits
%% no `step.started' or `tool.started' event for the omitted steps. The run is
%% started directly through soma_run:start_link/1 so the resume opts can be
%% passed. Here the full list is [s1, s2]; s1 is committed (seeded in `outputs',
%% omitted from `pending') and only s2 is pending. The recorded trail must carry
%% no `step.started'/`tool.started' for s1.
test_resume_emits_no_start_events_for_committed_steps(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-resume-no-start-1">>,
    FullSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
                 #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    Pending = [#{id => s2, tool => echo, args => #{value => <<"b">>}}],
    Outputs = #{s1 => #{value => <<"a">>}},
    {ok, _RunPid} = soma_run:start_link(#{run_id => RunId,
                                          session_id => <<"sess-resume-1">>,
                                          event_store => StorePid,
                                          steps => FullSteps,
                                          pending => Pending,
                                          outputs => Outputs}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    StartEvents = [{maps:get(event_type, E), maps:get(step_id, E, undefined)}
                   || E <- Events,
                      lists:member(maps:get(event_type, E),
                                   [<<"step.started">>, <<"tool.started">>])],
    %% no start event names the committed step s1
    false = lists:any(fun({_Type, StepId}) -> StepId =:= s1 end, StartEvents),
    %% the pending step s2 did run, so its start events are present
    true = lists:member({<<"step.started">>, s2}, StartEvents),
    true = lists:member({<<"tool.started">>, s2}, StartEvents),
    ok.

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

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

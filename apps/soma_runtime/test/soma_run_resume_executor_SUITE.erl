-module(soma_run_resume_executor_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_between_steps_resume_starts_fresh_child_that_completes/1]).

all() ->
    [test_between_steps_resume_starts_fresh_child_that_completes].

init_per_testcase(_Case, Config) ->
    application:unset_env(soma_runtime, event_store_log),
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    ok.

%% Criterion 1: resume/3 on a run interrupted between steps starts a NEW
%% soma_run child under soma_run_sup -- a distinct pid from any prior run -- that
%% continues from next_step and reaches run.completed. Seed a between-steps trail
%% ([s1, s2], s1 committed via step.succeeded, s2 pending, no tool.started), call
%% resume/3, and assert: {ok, RunPid} where RunPid is a live child of
%% soma_run_sup, and the run reaches run.completed without failing.
test_between_steps_resume_starts_fresh_child_that_completes(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-between-steps-1">>,
    SessionId = <<"sess-exec-between-steps-1">>,
    Owner = self(),
    S1 = #{id => s1, tool => echo, args => #{value => <<"committed">>}},
    S2 = #{id => s2, tool => echo, args => #{value => <<"pending">>}},
    Steps = [S1, S2],
    RunOptions = #{run_id => RunId, session_id => SessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"committed">>}}}),

    Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    ?assertMatch({ok, _RunPid}, Result),
    {ok, RunPid} = Result,
    ?assert(is_pid(RunPid)),

    %% RunPid is a fresh child of soma_run_sup.
    ChildPids = [P || {_Id, P, _Type, _Mods}
                          <- supervisor:which_children(soma_run_sup),
                      is_pid(P)],
    ?assert(lists:member(RunPid, ChildPids)),

    %% the resumed run continues from next_step and reaches run.completed.
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Types = [maps:get(event_type, E)
             || E <- soma_event_store:by_run(StorePid, RunId)],
    ?assert(lists:member(<<"run.completed">>, Types)),
    ?assertNot(lists:member(<<"run.failed">>, Types)).

wait_for_run_completed(_StorePid, _RunId, 0) ->
    {error, timeout};
wait_for_run_completed(StorePid, RunId, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case lists:any(fun(E) ->
                           maps:get(event_type, E, undefined) =:= <<"run.completed">>
                   end, Events) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_run_completed(StorePid, RunId, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
